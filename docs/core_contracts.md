# E1.S2 core contracts

The root `silly` package now exports `Request`, `Context<A, S>`, `Response`, `Limits`,
header storage/access, typed outcomes and `MemoryTransport`. These are real low-level
operations. HTTP parsing/framing, sockets, routing, terminal guards, convenience response
helpers and resumable file/stream operations belong to later stories. The six reference
applications remain target sketches; no mock implementations were added for them.

## Driver-owned data and immutable request access

The driver owns request head/body bytes, the request `HeaderView` array, response
`HeaderField` array, response header bytes, response output, and application state.
`Request` stores const views into retained request storage. `Context<A, S>` stores
`request: const Request&`, `response: Response&`, and `app: A&`. It owns none of those
resources. `S` is a compile-time stream-state marker here; no stream state is retained yet.

`Request { method, target, headers, body_state }` includes the raw method/target views.
The default headers use a stable empty global array, not a temporary slice.
`RequestBody` is `Buffered { bytes }`, `Streamed`, or `Failed { error: BodyError }`.
An empty buffered body is valid. `body_view(request)` and `body_view(ctx)` return
`BodyView.Available { bytes }` or `Failed { error }`; streamed input reports `Unavailable`.
The target `ctx.body()` convenience/endpoint rejection policy is not implemented here.

Before invoking a handler, the coordinator calls
`validate_request(request, retained_head_size, limits) -> RequestError`. This checks
limits, aggregate header bytes/count, header syntax, body size and failed body state.
The supplied head size includes request line, separators and terminator. This is a
view/cap validation boundary, not a parser or proof that views actually came from one
wire request. E2 constructs those views and validates HTTP grammar/framing. Streamed
input is not collected here; E2/E7 enforce its incremental limits.

`header(request_or_ctx, name) -> FieldValue` trims leading/trailing SP/HTAB;
`header_raw(...)` trims leading SP/HTAB and retains trailing whitespace. Both preserve
missing versus present-empty and use the first case-insensitive match. Repeated headers
are available in insertion order using `find_header(headers, name, previous_index + 1)`.
Request fields borrow bytes; no request-header copy occurs during lookup. E4.S1 adds
`Request.header_index`, parser-built sorted source offsets, exact `header_wire`, and
`header_values` / `next_header` for all occurrences. See [header access](request_headers.md).

## Header and output builders

`HeaderView` borrows a name/value. `HeaderField` owns four integer offsets/lengths into
a separately owned byte buffer. `append_header(fields, storage, name, value, limits)`
returns `HeaderResult`: `Ok`, count/byte limit, invalid name/value, or invalid limits.
It checks all limits and syntax before mutating either owner, then copies bytes once.
Duplicate values retain insertion order. `header_view(fields, storage, index)` borrows
the byte owner and asserts internal offset invariants. Header names require token bytes;
values reject controls except HTAB and reject DEL, including CR/LF injection.

`Response { limits, header_fields, header_bytes, output, .. }` borrows three separate
growable owners. It has no owned resizable tail. Begin requires all owners empty, so
accidental reuse cannot concatenate old payloads. `MemoryTransport` owns one resizable
tail for captured payload bytes; it does not hold a response slice after a drain call.

Default `Limits`: 32 KiB request head, 100 headers, 32 KiB aggregate header name/value
bytes, 8 MiB buffered input, and 8 MiB buffered output. Header separators/wire framing
are accounted by the head cap on input and E2's writer on output. Zero header/body/output
limits are valid; the head limit must be positive. E2.S1 adds positive wire limits of
8 KiB per request line, 16 KiB per header line, and 16 KiB per header section, including
CRLF. See [request-head contracts](http_heads.md). Negative caps fail validation.
Independent `HeaderLimits` defaults are 64 fields/16 KiB; responses pass their explicit
`Limits` instead. Capacity checks subtract validated lengths to avoid overflow.

## Response lifecycle and outcomes

| Operation | Preconditions and effect | Result |
| --- | --- | --- |
| `begin_response(response, status)` | Empty state and empty owners; validate final status 200–599 and limits; select Preparing | `ResponseError.None` or explicit failure; repeated begin returns `AlreadyStarted` without replacing bytes/status |
| `append_body(response, bytes)` | Preparing only; copy bytes into bounded owned output | None or OutputLimit; capacity failure marks Failed and cannot commit partial output |
| `add_header(response, name, value)` | Preparing or Prepared; bounded atomic header append | None or typed header failure; bad metadata/limits mark Failed |
| `set_status(response, status)` | Preparing or Prepared; validate final status | None or failure |
| `prepare_response(response)` | Preparing; freeze body construction as Prepared | None or InvalidState |
| `commit_response(response)` | Prepared; enter Committed | None or InvalidState; metadata now immutable through checked operations |
| `complete_response(response)` | Committed with all output acknowledged | true exactly once, moves to Completed; otherwise false |
| `cancel_response(response, error)` | Any nonterminal state | true exactly once, moves to Cancelled; terminal calls return false |
| `fail_response(response, error)` | Precommit becomes Failed; committed becomes Cancelled | Returns supplied error; terminal states remain unchanged |

`ResponseError` distinguishes invalid limits/status/state, already-started response,
body/header capacity, invalid metadata, missing response, transport and application errors.
Operations returning a failure must be handled. Refused late writes and repeated begins
do not themselves destroy an existing response. Failed preparation is uncommittable;
the coordinator can discard it and use application conversion before wire commitment.

`handler_outcome(response, RouteSelection)` distinguishes `Prepared`, `RouteNotFound`,
`MissingResponse`, and `Failed { error }`. A deliberately prepared zero-byte response is
success; unmatched without a response is route-not-found; matched without a completed
builder is missing-response. A prepared application fallback succeeds even on NotFound.
Selection is independent of response phase. Transport states are not handler success.

Goose struct fields are visible. Response state, offsets and driver buffer references are
coordinator internals; application code uses checked operations. Direct field mutation
can bypass protocol invariants and is not supported. The compiler protects storage
lifetimes; checked functions protect runtime lifecycle transitions. Header/body semantics
for HEAD, 204/304 and interim 100 responses belong to E2's HTTP writer/parser.

## Application error conversion

`convert_error(ctx, app_error, named_converter) -> HandlerOutcome` statically calls
`converter(Context<A,S>&, E)` on a fresh Empty response. Application errors keep their own
type and choose their own status/body. The converter must prepare a response; its absent
or failed response is reported normally. No runtime callback storage is involved.

After failed preparation, first end the old response/context/output borrows, clear or
discard their driver-owned buffers, then construct a fresh response/context and invoke
conversion. The API refuses to overwrite a Preparing/Prepared/Failed response. After
commit it cancels with Application error and does not call the converter. Completed or
cancelled responses remain terminal. The coordinator chooses a bounded fallback if
conversion fails; E3/E5 will connect this policy to terminal guards and lifecycle hooks.
`recover_failed_builder` in `tests/handlers/context_test.goose` exercises this sequence.

## Lifetime rules by source

| Source | Root, copy and expiry rule |
| --- | --- |
| Borrowed request/body/header view | Root is retained driver storage; keep it live and unreset through the last dependent use. Context cannot outlive its request/application/response owners. |
| Handler-local payload | `append_body` copies once into response-owned output during the call; local bytes may expire afterward. No asynchronous borrow is retained. |
| Static literal | Process-lived input, but this buffered API still copies it; no separate zero-copy static-body mode is claimed. |
| Owned buffered output | Driver buffer remains live through transport acknowledgement or cancellation; no reset/reuse while views are still used. Future native transport must retain owner IDs/offsets, not borrowed handler addresses. |
| File/proxy operation (future) | E8/E9 must transfer descriptor/operation ownership to the driver, retain bounded metadata, and release once on completion/cancel. No fake handle variant is exposed in E1.S2. |
| Stream state/chunk (future) | E1.S4/E7 prove fixed-size owned state between steps. Step/input views expire on return; queued output cannot be reused before acknowledgement. |

Grow-only append preserves existing views. Clear/shrink with a later dependent use is
rejected by the compiler. Last-use analysis can permit reset before the lexical scope
ends; do not rely on lexical scope alone. There is intentionally no public response-reset
operation hiding behind references: end old borrows, reset owners, construct fresh state.

## Memory transport and verification

`drain_memory(transport, response, allowance)` requires Committed state. It copies at most
the allowance, remaining output and sink capacity, preserving `sent_bytes`. Results are
Progress, Blocked, Complete, Failed or InvalidState. A full sink/zero allowance blocks;
disconnect/invalid sink capacity cancels. An empty response completes even with zero
capacity. `terminal_count` records terminal transitions made by that sink exactly once.
It captures payload bytes, not HTTP framing; E1.S3/E2 provide real transport/wire output.

Functional fixtures: `tests/handlers/context_test.goose`, `tests/request/request_test.goose`,
`tests/request/headers_test.goose`, and `tests/support/consumer_import.goose`. Build each with
`goose build <fixture> --offline -O2 -o /tmp/<name>` and again with `-O0 --debug`, then run
each binary. Check formatting using the repository goosefmt formatter and config.
The context suite covers empty/missing/duplicate responses, metadata commitment,
capacity failures, partial/blocked/disconnected drains, terminal-once behavior and
custom conversion after discarding failed builders.

[Lifetime fixtures](../tests/lifetimes/README.md) include one positive public-context
example and four intentionally rejected programs. Check each at `-O2` and `-O0 --debug`;
match its expected lifetime diagnostic, not merely any nonzero compiler exit. The
positive example must have no copy-on-return warnings. Do not build all `.goose` files
as runnable programs: rejection fixtures and future reference sketches are intentional.

E1.S2 verification passed on macOS arm64 with Goose runtime `4d3da949e563`, Apple clang
17.0.0: all five positive programs built and ran at `-O2` and `-O0 --debug`, without
copy-on-return warnings. All four negative fixtures matched their intended diagnostic
in both modes. Formatter and whitespace checks passed. Header-fixture `--stacks` reports
four data-stack regions (default 2 GiB virtual reservation each, not resident allocation);
`--bce-lines` eliminates all six index checks, retaining two of four slice checks for
offset-derived header views. No `checkfree` annotation or throughput claim is made.
Linux remains unverified in this workspace. No native dependency was added.

E1.S3 subsequently reran these fixtures successfully on Linux as well; see
[native server verification](native_server.md#verification) for current platform evidence.

E2.S2 adds `Request.body_framing` (None/Fixed/Chunked) independently of body length.
The driver exposes an empty or nonempty Buffered body only after complete framing; failed
or incomplete bodies never reach ordinary handlers. See [request bodies](request_bodies.md).

E2.S3 adds wire-level status/method rules and an atomic head plan without changing the
final-response builder lifecycle. The server invokes an optional static error renderer
on fresh owners before commitment; see [response serialization](response_wire.md).
