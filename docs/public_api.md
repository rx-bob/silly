# Public API design history and implemented contracts

The package now implements routing, request/response helpers, lifecycle scheduling,
streams, files and the optional client/proxy. All reference applications build in
debug and optimized modes. Start with the current [README](../README.md),
[handler guide](handlers.md) and [streaming guide](streaming.md); those guides link
working examples and explicit public declarations.

The API tables below preserve the initial E1 specification notation and are followed
by story-specific implementation contracts. Names that describe interface roles are
not additional declarations. Omitted generic parameters are inferred, `void` means
no value, and callback names denote compile-time arguments rather than runtime
function fields. `bytes` denotes a const-generic `u8[:]` parameter; stored read-only
views use `const u8[:]`. Where an initial sketch differs from the shipped API, the
implemented source and later contract sections govern, including the explicit typed
static-file handler replacing the proposed `router.files` action.

Custom writer calls use `silly::append(out, bytes)`; array-style `out.append` is not
supported for custom writers by this compiler. Failed producer steps receive one
Cancelled cleanup event; Done steps release resources before returning. The
[continuation contracts](continuations.md) and [core contracts](core_contracts.md)
record compiler-tested lifetime and response-phase rules.

## Source and implementation status

| Reference | Contract exercised | Implementation owners |
| --- | --- | --- |
| [app.goose](../reference/app.goose) | Startup routes, typed handler, text and typed JSON | E1.S3, E3.S1–E3.S3, E4.S3, E5.S1 |
| [promptnook.goose](../reference/promptnook.goose) | Scopes, CORS, serialized native state, raw inputs, lifecycle | E3.S2–E3.S3, E4.S1, E5.S2–E5.S3, E6.S3–E6.S4 |
| [responses.goose](../reference/responses.goose) | HTML, query/form, JSON bytes, binary, attachments, redirects, guards | E4.S2–E4.S3, E5.S1, E3.S3, E8.S1 |
| [streaming.goose](../reference/streaming.goose) | Owned SSE producer state and completion hooks | E1.S4, E5.S2, E7.S1, E7.S3 |
| [request_stream.goose](../reference/request_stream.goose) | Streamed request input, bounded output and cancellation | E2.S2, E7.S1–E7.S2 |
| [files_and_portal.goose](../reference/files_and_portal.goose) | Static files, query policy, retained proxy operations | E4.S2, E8.S1–E8.S4, E9.S1–E9.S4 |

All six are implemented executable consumers. PromptNook uses deterministic contract
handlers instead of unresolved `application::` placeholders; real domain behavior
remains application-owned. Standard library calls (`str`, `print`, `exit`) and
application callbacks/types are not Silly API.
[dispatch_proof.goose](../reference/dispatch_proof.goose) is a separate narrow proof:
it uses production preparation/matching plus a local endpoint-guard exercise. It is
not an HTTP server or evidence by itself for scheduler, queue or retained-state safety.
Those contracts have their own executable tests and the E10 integration suites.

## Shared ownership and failure rules

`R` is an application route enum. `A` is flat owned initialization data copied into each execution
owner. Mutable app state stays owner-local; live native handles must be created and released by
that owner's Start/Stop hooks. `S` is fixed-size state: scalars, bounded inline arrays, or tagged
payloads. Larger resources require generation-checked IDs into bounded owner pools. Neither `A`
nor `S` may smuggle references to departed handler frames across owners or scheduler turns.

Response helpers synchronously prepare one response. They do not write sockets or implicitly
return from the handler. A missing response, duplicate response, invalid metadata, or exhausted
buffer is a classified endpoint failure. Capacity failures unwind to the endpoint coordinator,
which ends builder borrows before creating an error response. `reject_*` and failing `require_*`
also exit the named endpoint boundary, so following handler statements do not run. A prepared
rejection remains the selected response. These rules belong to E1.S2, E2.S3, E3.S3, and E5.S2.

Before header commitment, metadata can be prepared within bounds. After commitment, failures
cancel/close the transfer; they cannot change status or create a second response. Queued bytes
remain owned until transport acknowledges consumption. Completion/cancellation releases each
resource once. Buffer or pool reuse requires both ended borrows and matching generation IDs.
These rules apply to every response row below, including file/proxy/stream modes.

## Entry points and configuration

| Signature or type | Ownership and behavior | Failure contract | Owner |
| --- | --- | --- | --- |
| `serve<R>(options: ServerOptions, define, handle) -> ServerResult` | `define(Router<R>&)` runs during preparation; `handle(Context<NoState, NoStream>&, R)` runs for the selected route. Supplies default no-state, no-stream and lifecycle adapters. | Invalid configuration, route preparation, listener or startup failure returns unsuccessful result; shutdown failure is explicit. | E1.S3, E3.S1, E6.S4 |
| `serve<R,A>(options, app: A&, define, handle, lifecycle) -> ServerResult` | `define(Router<R>&, A&)`; `handle(Context<A, NoStream>&, R)`; `lifecycle(A&, Lifecycle<R>) -> HookResult`. Copies initialization data into owners; borrows each owner during callbacks. | Same startup/shutdown contract; failed Start prevents that owner accepting work. | E3.S3, E5.S2, E6.S1–E6.S4 |
| `serve<R,A,S>(options, app: A&, define, handle, step, lifecycle) -> ServerResult` | As above with `Context<A,S>` and `step(S&, StreamEvent, ChunkWriter&) -> StreamStep`. Scheduler owns `S`; callbacks do not escape. | Startup errors as above; stream failures terminate only through explicit outcomes and coordinated shutdown policy. | E1.S4, E7.S1–E7.S2, E6.S4 |
| `NoState`, `NoStream` | Empty marker types for applications without app or producer state; implemented by E1.S1. | No resources or failure behavior. A NoStream app cannot start a typed producer. | E1.S1; context integration E1.S2 |
| `ServerOptions { address, port, limits, .. }` | Address is copied/retained in bounded server-owned configuration before its source can expire; port is validated. `limits: Limits`; other settings govern workers/execution. Data only, no callbacks. | Invalid address, port, limits or worker/lane settings fail preparation before admission. | E1.S3, E6.S1–E6.S2 |
| `Limits { body_bytes_max, .. }` | Named finite caps for heads/fields, bodies, paths/captures, output/chunks, connections, queues, ranges, directory work and deadlines. `body_bytes_max` bounds buffered collection; streamed routes retain bounded chunks rather than a whole body. | Reject inconsistent/overflowing configuration; external limit violations are operating errors, not assertions. Each owning subsystem documents defaults and boundary outcomes. | E1.S2; E2, E3, E6, E7, E8 extend relevant caps |
| `ServerResult { ok: bool, message }` | Result and bounded diagnostic remain owned after `serve` returns. Importing the library never owns main or installs signals. | `ok = false` includes startup failure and incomplete drain; noncooperative native work is not promised safe forced termination. | E1.S3, E6.S4 |

Registration can replay deterministically during owner preparation, never per request. Neither
registration callbacks nor handlers are stored as runtime closures. `..` in reference literals
means defaults supplied by the owning implementation story; it does not authorize unbounded
capacity or an implicit change to the explicitly supplied policy.

## Registration and execution selection

All registration calls borrow `Router<R>&` and return no value. Preparation copies retained path,
method and policy strings into bounded router-owned storage; no registration-local slice escapes.
Invalid patterns, ambiguous/conflicting registrations, unsupported policies and capacity overflow
become preparation errors reported by `serve`, before requests are accepted.

| Signature | Additional behavior and ownership | Owner |
| --- | --- | --- |
| `get/post/put/patch/delete/head/options(router, path: bytes, action: R, options?: RouteOptions)` | Registers one explicit method; aliases require separate registrations. Stores the typed route value. | E3.S1–E3.S2 |
| `any(router, path: bytes, action: R, options?: RouteOptions)` | Application fallback method. A specific method registration wins. | E3.S1–E3.S2 |
| `scope(router, prefix: bytes, define_group)` | Calls `define_group(group)` immediately; group paths are relative, policy inheritance is a snapshot. Group and block cannot escape preparation. | E3.S2 |
| `execution(group, execution: Execution)` | Selects execution domain for subsequent declarations and their lifecycle hooks. | E6.S2–E6.S3 |
| `cors(group, policy: CorsPolicy)` | Snapshots policy for subsequent group routes, errors and fallback/preflight responses. | E5.S3 |
| `static_mount_response(ctx, mount: FileMount, path?: bytes)` | Selects an owned `StaticTransfer` from an ordinary typed route; native workers perform lookup, gzip selection and listing. Specific routes precede the static catch-all. | E8.S4 |

| Configuration | Fields/variants in references and failure behavior | Owner |
| --- | --- | --- |
| `RouteOptions` / `BodyMode` | `body: BodyMode.Streamed` opts into streamed input. Default is bounded buffered input. Unsupported combinations fail preparation; streamed mode forbids buffered body extraction. | E2.S2, E3.S1, E7.S2 |
| `Execution.Serialized { lane }` | Bounded lane name resolves before admission. All native-state operations, including lifecycle hooks and whole multi-call transactions, use the same process-wide lane. Unknown/invalid lane fails startup. Goose thread isolation does not isolate C statics. | E6.S2–E6.S3 |
| `CorsPolicy { origin, methods, headers, preflight_status, .. }` | Retained text is validated/copied during preparation. Example permits `*`, listed methods/headers and status 200. No implicit authentication. Malformed policy is a preparation error. | E5.S3 |
| `FileMount { executor, root, directory_policy, missing_policy, gzip_freshness_ms, .. }` | Uses application-owned executor/root handles. Explicit `List` and `RootListing` policies reproduce Portal behavior; `gzip_freshness_ms: 10` selects its tolerance. Invalid caps fail selection. | E8.S4 |

File operations retain validated open-file resources, not request-local filename slices. MIME,
HEAD and validators belong to E8.S2; bounded single/multiple ranges to E8.S3; selected gzip
representation, slash redirects retaining queries and directory/fallback policy to E8.S4.

## Request access and decoding

`Context<A,S>` borrows the request owner, response owner and execution-local app for one endpoint
invocation. `ctx.app` is an `A&` valid only in that domain; it is not cross-thread shared state.
`FieldValue { present: bool, value: const u8[:] }` distinguishes missing from present-empty.
All request views expire with retained request storage, not merely with the helper call. Scratch
views additionally require scratch to remain alive and unmodified; do not grow/reset scratch
while dependent borrows remain. E1.S2 defines these roots; E3.S3 exposes typed app access.

| Signature | Ownership and result | Failure contract | Owner |
| --- | --- | --- | --- |
| `param(ctx, name: bytes) -> FieldValue` | Raw named capture borrows request target; no percent decoding. Presence remains observable for optional/catch-all captures. | Unknown name returns absent; an empty catch-all remains present. | E3.S2 |
| `header(ctx, name: bytes) -> FieldValue` | Case-insensitive lookup; trimmed value borrows retained head. | Absent returns `present = false`; malformed input was rejected by parser. Repeated values use header_values/next_header; exact whitespace uses header_wire. | E4.S1 |
| `header_raw(ctx, name: bytes) -> FieldValue` | As above, trims leading whitespace but preserves trailing whitespace. | Same as `header`; no auth interpretation. | E4.S1 |
| `body(ctx) -> const u8[:]` | Exact decoded buffered body, including empty body; borrows body owner. | Invalid on streamed route; framing/size failures are handled before a buffered handler runs. | E1.S2, E2.S2 |
| `query(ctx, name: bytes, scratch: u8[>..]&) -> FieldValue` | First decoded match; borrows input when no transform is needed, otherwise caller scratch. Distinguishes absence and empty. | Strict default rejects malformed decoding through endpoint boundary; bounded decoded-size/pair failures are explicit. Literal-invalid behavior requires the explicit policy operation. | E4.S2 |
| `query_pairs(ctx, scratch, options?: QueryOptions) -> QueryView` | Ordered bounded pairs preserve repetitions, empty entries and whether equals was present; views borrow input/scratch. | Malformed escapes follow explicit policy; pair/decoded-size limits fail through endpoint boundary. | E4.S2 |
| `without_query_keys(pairs: QueryPairs or QueryView, keys: bytes[:], match?: KeyMatch) -> QueryPairs` | Fresh bounded filtered pair collection; retained values still borrow original input/scratch. Does not rewrite caller collection. | Capacity failure is explicit; no truncation or accidental deduplication. | E4.S2 |
| `require_form(ctx, scratch) -> Form` | Opt-in URL-encoded form parser; result views borrow body/scratch. | Invalid media type, malformed input or exceeded limits prepares rejection and exits endpoint. | E4.S2 |
| `get(form: Form, name: bytes) -> FieldValue` | First decoded field; view borrows form's body/scratch roots. Repetitions remain available in parsed data. | Missing is a normal absent result, not rejection. | E4.S2 |
| `require_json<T>(ctx, scratch) -> T` | Typed opt-in binding; unescaped strings may borrow body, decoded strings borrow scratch. Returned fresh value is constructed in caller destination. | Media/type/required-field/depth/collection failures reject endpoint. Named field policies and JsonPresence distinguish missing/null/default; duplicate and unknown fields reject by default, with explicit alternatives. Raw-body APIs preserve legacy diagnostics. | E4.S3 |

`QueryOptions { separators, invalid_escape }` copies no request data by itself: separators are
borrowed during synchronous decoding. Default separator is `&`; the Portal sketch explicitly
uses `&;`. `InvalidEscape.Literal` preserves malformed query escapes; strict decoding rejects
them. `KeyMatch.AsciiIgnoreCase` removes all ASCII-insensitive matches, with exact matching as
the default. These policies do not relax filesystem path decoding or cause double decoding.
All belong to E4.S2. `Form` wraps a fixed borrowed query view; `QueryPairs` owns bounded metadata with borrowed values,
not independent deep copies of every value; proxy preparation must copy their bytes before the handler/scratch expires.

## Buffered response operations

Every row borrows `Context<A,S>&`, returns no value, and uses the shared endpoint failure rules.
Inputs are consumed synchronously. Buffered bytes are copied into response-owned storage;
serialization and HTML writing append directly there. Successful return means prepared, not
delivered. Byte slices supplied by application locals may expire after the call.

| Signature | Behavior, metadata and validation | Owner |
| --- | --- | --- |
| `text(ctx, status: i32, payload: bytes)` | Prepares text/plain bytes; validates status and enforces output cap. | E5.S1 |
| `html(ctx, status: i32, render)` | Invokes static `render(out: EndpointWriter&)` immediately; produces HTML. Writer cannot escape callback. | E5.S1 |
| `append(out: EndpointWriter&, trusted_markup: bytes)` | Copies trusted markup literally. Capacity failure exits endpoint coordinator; no partial response commitment. | E5.S1 |
| `html_text(out: EndpointWriter&, text: bytes)` | Escapes HTML data/RCDATA text directly into bounded output; same capacity failure behavior. Not script, CSS, URL or attribute escaping. | E5.S1 |
| `html_attribute(out: EndpointWriter&, text: bytes)` | Escapes ordinary quoted attribute values, including both quotes and line whitespace. Caller writes surrounding quotes. | E5.S1 |
| `empty(ctx, status: i32)` | Prepares an empty body without Content-Type. | E5.S1 |
| `json<T>(ctx, status: i32, value: T)` | Direct serializer; supported scalar/struct/collection shapes and explicit wire-name/custom writers. Unsupported static types are compiler errors; runtime depth/output failures use endpoint boundary. | E4.S3 |
| `json_bytes(ctx, status: i32, payload: bytes)` | Opaque application JSON with JSON media type. No reparsing or rewriting keys, duplicate fields, number spelling or diagnostics; caller owns JSON validity. Metadata/output limits still apply. | E4.S3, E5.S1 |
| `bytes(ctx, status: i32, payload: bytes, options: BodyOptions)` | Arbitrary binary bytes; empty `BodyOptions {}` deliberately omits Content-Type. Any supplied metadata is validated and copied. | E5.S1 |
| `attachment(ctx, status: i32, payload: bytes, attachment: Attachment)` | `Attachment { filename, content_type }` supplies validated Content-Disposition/MIME metadata. Copies payload once; rejects unsafe header/filename input. ZIP construction remains application-owned. | E5.S1, E8.S1 |
| `redirect(ctx, status: i32, location: bytes)` | Validated Location with empty body; rejects header injection and invalid status/metadata. | E5.S1 |
| `reject_text(ctx, status: i32, payload: bytes)` | Prepares text rejection then returns from named endpoint boundary. Following caller statements cannot run. Same status/output limits apply. | E3.S3, E5.S1 |

## Lifecycle and execution owner

| Signature or type | Ownership and behavior | Failure contract | Owner |
| --- | --- | --- | --- |
| `Lifecycle<R>.Start { owner }` / `.Stop { owner }` | Once per execution owner, in its domain. Native resources start/stop there. | Failed Start blocks admission; Stop failure is reported without inventing a response or pretending cleanup succeeded. | E6.S4 |
| `Lifecycle<R>.HandlerFinished { completion }` | Once after endpoint boundary, including rejection. No retained handler context. Parser failures need not emit this event. | Hook failure is classified; cannot fabricate a second response. | E5.S2 |
| `Lifecycle<R>.TransferFinished { completion }` | Once at actual delivery completion or cancellation, not at handler return. | Same rule; terminal release remains exactly once even if hook fails. | E5.S2, E7.S1 |
| `Completion<R>` | Stable bounded metadata: selected application/built-in/missing route, request ID, `status: i32`, terminal outcome and explicitly supplied audit data. Owned event data outlives endpoint; nested views are limited to hook invocation unless copied. | Missing route/aborted transfer are represented explicitly, never fabricated success. | E5.S2 |
| `HookResult.Ok` / typed owned failure | Returned by static lifecycle callback. Failure diagnostic does not borrow callback locals. | Startup failure stops preparation; completion/cleanup failures remain lifecycle errors. | E5.S2, E6.S4 |
| `is_serialized(owner: Owner, lane: bytes) -> bool` | Synchronous comparison of owner identity with configured lane; retains no supplied slice. | Nonmatching lane returns false; invalid configured lane already failed startup. | E6.S3–E6.S4 |

## Streaming and SSE

| Signature or type | Ownership and behavior | Failure contract | Owner |
| --- | --- | --- | --- |
| `events(ctx, state: S) -> void` | Copies/transfers fixed-size state into runtime owner and prepares SSE headers. Steps begin after handler return. | Shared response failures; state containing departed-frame borrows is forbidden. | E7.S1, E7.S3 |
| `stream_input(ctx, status: i32, state: S, options: StreamOptions) -> void` | Starts owned producer/consumer session. `StreamOptions { content_type, .. }` metadata is validated/copied during call. Route must be `BodyMode.Streamed`. | Mode mismatch, invalid metadata or exhausted resources is endpoint failure before commitment. | E7.S1–E7.S2 |
| `StreamEvent.Ready` / `.Input { bytes }` / `.InputEnd` / `.InputFailed { reason }` / `.Cancelled` | Runtime invokes a short synchronous step; input bytes borrow runtime chunk only for current step. No retained input reference. | Failure/cancellation is explicit; cancellation step releases producer resources without producing further output. | E7.S1–E7.S2 |
| `ChunkWriter` / `append(out: ChunkWriter&, payload: bytes) -> bool` | Borrows one bounded runtime-owned output chunk; copies payload during step. Transport owns produced bytes until drained. | Returns false when append cannot fit; failed output is never committed as a successful chunk. Caller returns `Failed`, as references do. | E7.S1 |
| `StreamStep.Chunk { flush: bool, next: Wake }` | Hands prepared chunk to transport; next step waits for drain/capacity and specified wake. Flush requests progress, not synchronous delivery. | Transport failure cancels; no rewrite of committed headers. | E7.S1–E7.S2 |
| `StreamStep.Wait { wake: Wake }` | Produces no chunk and yields to readiness/input/timer scheduler. | Invalid/unbounded wake is a classified stream failure; no busy-loop polling promise. | E7.S1 |
| `StreamStep.Done` / `.Failed { reason: StreamError }` | Terminal producer outcomes; release runtime/state resources once. Failure reason is retained safely. | `Failed` closes/cancels after commitment; precommit failure follows response policy. | E7.S1 |
| `Wake.Input` / `.After { delay_ms }` / readiness wake | Input is requested explicitly; delay is finite, nonnegative and checked for clock arithmetic overflow. | Invalid wake configuration fails stream; disconnect/deadline becomes cancellation. | E7.S1–E7.S2 |
| `StreamError.OutputLimit` | Classifies bounded writer exhaustion; input and transport errors also carry explicit typed reasons. | No truncation or silent success. | E7.S1–E7.S2 |
| `sse_event(out: ChunkWriter&, event: SseEvent) -> bool` | `SseEvent { event, data, .. }` borrows inputs only during formatting. Escapes/formats SSE fields and multiline data directly into current chunk; optional id/retry fields use bounded validated metadata. | False for invalid event fields or insufficient capacity; caller terminates with explicit stream failure. No whole-stream buffer. | E7.S3 |

## Isolated outbound proxy package

| Signature or type | Ownership and behavior | Failure contract | Owner |
| --- | --- | --- | --- |
| `silly_client::proxy(ctx, request: ProxyRequest) -> void` | Synchronously prepares retained operation, copying needed URL/query/auth/header data into bounded operation-owned storage. Body transfer is incremental with backpressure. No scratch or handler slice survives by borrowing. | Preparation uses endpoint failures. DNS/TLS/connect/upstream failures use explicit proxy mapping before commitment and cancellation/close afterward. | E9.S1–E9.S3 |
| `ProxyRequest { base_url, path, query, authorization, compression, .. }` | Base URL/path joined safely; query is ordered, preserving repeated pairs. Application selects target and filtering. Input views only need survive preparation. Headers/framing are forwarded under explicit policy. | Invalid URL, unsafe metadata and capacity excess fail preparation; no implicit fallback to another upstream. | E9.S3–E9.S4 |
| `Authorization.Bearer { token }` | Token borrowed during proxy preparation, then copied into bounded owned authorization metadata. | Reject header-injection bytes; application owns token validity and environment selection. | E9.S2–E9.S3 |
| `Compression.Automatic` | Chooses outbound automatic content negotiation/decoding policy; decoded byte stream and forwarded encoding/length headers must agree. Explicit versus implicit compression remains distinguishable. | Unsupported/failed decoding is a typed client/proxy failure; size limits apply to decoded bytes too. | E9.S2–E9.S4 |

The client package uses the isolated libcurl multi adapter for HTTP/HTTPS, TLS/DNS, connection
reuse and bounded pause/resume. Core-only consumers do not import/link it. The sketch's
`without_query_keys(..., ["environment"], KeyMatch.AsciiIgnoreCase)` removes only the selected
query key; authentication, environment resolution, application audit contents and MCP protocol
payload semantics remain consumer responsibilities.

When compiler/lifetime evidence requires a change, update the affected source sketch, this
contract and owning story together. Do not substitute request-time callback chains, retained
closures, unbounded buffers or a different handler/stream model without documenting that change.

E3.S1 now implements basic `serve<R>`, registration, prepared inventory and static
dispatch; see [routing contracts](routing.md). App/lifecycle/stream overloads remain
later-story contracts. The reference app now builds with typed JSON and `respond_text`.

E4.S1 now supplies a parser-built sorted header index, exact `header_wire`, and
ordered `header_values` / `next_header` cursors with Trimmed/Raw/Wire modes. See
[request header access](request_headers.md) for offsets, singleton handling and lifetimes.

E2.S2 now provides `BodyReader`, `read_body`, `collect_body`, `finish_body` and independent
`BodyLimits`. `RouteOptions.body_bytes_max` defaults to -1 (inherit) or tightens the server
cap. Collected bodies and Expect admission run on the production socket path; application
stream-input callbacks remain E7. See [body reader contracts](request_bodies.md).

E2.S3 now supplies atomic `prepare_response_head`, informational heads, bounded chunk
framing and `write_wire` over stable separate segments. `serve_with_errors<R>` and its
prepared/buffered variants accept a static `render(Response&, ResponseFailure)` callback.
See [response wire contracts](response_wire.md) for version/status rules and hook scope.


E3.S2 implements `RoutePolicy { head_from_get, automatic_options, method_not_allowed }`
(all false by default), scoped policy snapshots, generated 204/405 with bounded `Allow`,
`param(ctx, name)`/`ctx.param(name)`, and atomic `decode_path(out, raw, cap)` for explicit
single-pass percent decoding. See [routing contracts](routing.md) for precedence,
raw slash/encoding behavior, fallback envelopes and borrowed capture lifetimes.


E3.S3 implements the named endpoint boundary and typed single-owner state overload:
`serve<R,A>(options, app, define, handle)`, plus `_with_cleanup` and
`_with_cleanup_and_errors` variants. Cleanup is `cleanup(A&, HandlerOutcome)` after
handler return/rejection/cancellation. `reject_text`, `reject_empty` and `reject` exit the
checked boundary; `respond_text`/`respond_empty` return local errors. See
[endpoint contracts](endpoint.md). Full Lifecycle callbacks remain later stories.


E4.S2 now implements bounded raw/decoded query access, explicit literal-invalid query
compatibility, strict path decoding and URL-encoded forms. `QueryOptions` adds finite
input/pair/decoded byte caps; `parse_query` and `parse_form` return local errors, while
`query`/`query_pairs`/`require_form` use the endpoint guard. See
[URL/query/form contracts](url_query_forms.md) and runnable `examples/form.goose`.

E4.S3 implements exact `body`/standard `json_reader`, typed JSON binding with explicit
field policies, aliases and presence, bounded direct writers, static collection adapters
and opaque `json_bytes`. See [JSON contracts](json.md) for supported types, ownership,
custom callbacks, limits and raw application compatibility.

E2.S4 enables sequential HTTP/1.1 and opt-in HTTP/1.0 persistence with bounded queued
input. Configured renderers also receive classified request-head/body, admission and
timeout failures; unsafe or unread framing forces close. See [connection contracts](connections.md).

E5.S1 implements the buffered response helpers above, with separate text/quoted-attribute
escaping and compiler-checked callback writer lifetimes. See [response contracts](responses.md)
for metadata rules, local-error variants and the runnable `examples/web.goose` form.

E5.S2 implements buffered `serve<R,A>(options, app, define, handle, lifecycle)` and
`run_prepared_server_with_lifecycle`, plus lifecycle variants accepting a custom error
renderer. `middleware` composes static global/group/route guards under one endpoint;
`middleware_complete` unwinds entered layers outside it. `Lifecycle<R>` carries fixed
owned completion records, with real transfer delivery/cancellation and bounded opt-in
audit captures. See [middleware and lifecycle contracts](middleware.md). Stream scheduling
and execution lanes remain later-story work.

E5.S3 implements `router.cors(CorsPolicy)` and `router.error_policy(id)` with immutable
scoped snapshots. Unknown paths select the longest configured literal prefix; known routes
retain their registration-time policy. CORS canonicalization runs before wire staging on
normal and rendered error responses. `ResponseFailure` includes owned policy/method/target
and selected audit metadata for static consumer-envelope dispatch. See [CORS and error
policy contracts](cors.md), including the global invalid-head policy and fixed bounds.

E6.S1 adds [bounded independent I/O workers](runtime.md): a supervisor transfers accepted
sockets through addressed queues to private connection pools, app owners and immutable
route plans. `run_runtime` takes a concrete application `thread_fn` bridge because Goose
thread entrypoints cannot be generic. Existing `serve` remains single-owner.

E6.S2 adds [bounded blocking executors](executors.md): `RouteOptions.execution` selects
`ExecutionClass.Inline` or numeric `Lane { index }`; `run_runtime_with_executor` takes
concrete I/O and lane bridges. `run_executor_lane` initializes a private app/route plan
and runs the whole endpoint on that lane. HandlerFinished belongs to the lane;
TransferFinished belongs to the socket owner.


E6.S3 adds named native ownership: `ExecutorOptions.serialized_name` binds one bounded
name to executor lane zero; `Execution.Serialized { lane }` selects it. The `Execution`
alias names `ExecutionClass`. `router.execution(...)` snapshots inherited scope policy,
while explicit route options override it. `Owner.is_serialized(name)` gates lane-only
native Start/Stop. The [PromptNook reference](../reference/promptnook.goose) now uses
concrete I/O/lane bridges and copied startup seed; native global-state inventory and
migration limits are recorded in [consumer requirements](promptnook_requirements.md#e6s3-native-ownership-boundary).

### E6.S4 concrete runtime contract

See [shutdown and deadlines](shutdown.md) for `run_runtime_listeners`,
`run_runtime_listeners_with_executor`, opt-in `install_shutdown_signals` /
`uninstall_shutdown_signals`, and `resume_shutdown`. `ServerResult.drain` distinguishes
complete, incomplete and poisoned failure. An incomplete result owns `pending`; retain
it until resumed. `unrecovered_owners` identifies foreign resource owners after abort.
Phase timeout settings live in `ServerOptions` and `WorkerOptions`; completion records
retain the typed timeout reason. Production HTTP stream scheduling remains E7 work.

## E7.S1 streaming producers

`stream(ctx, status, owned_state, StreamOptions)` selects a bounded producer response.
`serve<R,A,S>(options, app, routes, handle, step, lifecycle)` is now a production
single-owner overload. `step` has the exact `S&, StreamEvent, ChunkWriter& -> StreamStep`
shape. One chunk, configurable from 1 through 4096 bytes, stays owned until transport
acknowledges it. See [streams](streams.md) for readiness, commitment, failure and cleanup.

Next: E7.S2 connects streamed request input and completes the HTTP stream matrix.

## E7.S2 streamed request bodies

Inline routes may select `BodyMode.Streamed`; the typed streaming owner dispatches
the handler after headers with `RequestBody.Streamed`. `stream_input` selects demand-driven
Input/InputEnd/InputFailed events and the same bounded producer writer. Decoded total
limits are independent of buffered-request storage. See [streamed HTTP](streamed_http.md).

Next: E7.S3 adds bounded SSE formatting and the cancellable event example.

## E7.S3 server-sent events

`events(ctx, owned_state, SseOptions)` selects a 200 SSE response.
`sse_event(out, SseEvent)` and `sse_comment(out, text)` format atomic bounded UTF-8
frames. Ordinary headers expose Last-Event-ID; application code owns replay policy.
See [SSE](sse.md) and the finite `examples/events.goose` source.

## E8.S1 rooted file responses

`open_file_root` and `start_file_executor` configure explicit bounded filesystem work.
`open_file` admits a worker-owned token; `file_response` transfers it to a
`Context<App,FileTransfer>` only after metadata succeeds. Use the ordinary typed
streaming serve overload with `file_step`. FileOptions controls offset/length, content
type and optional attachment filename; files and generated ZIP bytes remain opaque.
See [files](files.md) for path policy, handle ownership and nonblocking shutdown.


## E8.S2 static metadata and validators

`static_file_response(ctx, owned_file, path, StaticFileOptions)` adds MIME selection,
charset policy, descriptor-derived Content-Length/Last-Modified/weak ETag and GET/HEAD
conditional requests. `file_step_with_validator` accepts a static
`FileMetadata -> FileValidator` callback; an explicit options ETag takes precedence.
HEAD and 304 retain representation metadata through the shared writer and suppress
all body reads. See [files](files.md) for options, bounded conditional storage and
same-descriptor guarantees. E8.S3 extends the same API with range negotiation.


## E8.S3 bounded range responses

`StaticFileOptions { ranges: true, ranges_max: 16, .. }` enables GET range selection
on the opened representation. `parse_file_ranges` returns `RangePlan` with up to 16
ordered `ByteRange { offset, length }` entries. Valid selected ranges produce 206;
a valid list with no bytes produces 416. Invalid syntax, unknown units, overflow,
exceeded range/framing bounds or duplicate Range fields fall back to full 200.
Single ranges carry Content-Range; multiple ranges stream `multipart/byteranges`
with bounded framing storage and exact Content-Length.

Conditional 304 takes precedence. HEAD ignores ranges and suppresses every body.
If-Range needs strong ETag equality or an exact date match with an explicit
`FileValidator.last_modified_strong` guarantee; mismatch returns full 200. See
[files](files.md) for bounds, overlap policy, validator strength and Portal corrections.


## E8.S4 static mounts

The implemented mount API uses an ordinary typed catch-all route and
`Context<App, StaticTransfer>`. Select with `static_mount_response(ctx, mount, path?)`
and supply `static_file_step` as the producer, or
`static_file_step_with_policy(state, event, writer, validator, policy)` for static
application callbacks. `FileMount` carries already-open `FileRoot` and `FileExecutor`
handles; their lifetime remains with application startup/shutdown.

This revises the proposed `router.files` built-in action: explicit typed dispatch
preserves the existing callback and stream ownership model without hidden route
closures. The now-executable [Portal reference](../reference/files_and_portal.goose)
uses only implemented APIs. The separate proxy remains E9 work.

`StaticLookupEvent` reports `Directory` or `Missing`, the owned selected path,
underlying error, mount settings and fallback count. `StaticAction` chooses `Reject`,
`List`, or `ServePath` with an owned replacement path. This expresses optional index
or SPA behavior without assuming either. The default policy uses explicit
`directory_policy`/`missing_policy` and otherwise rejects with 404. Only GET/HEAD
enter filesystem lookup; other methods return 404 to match Portal.

See [files](files.md) for negotiation, selected-representation validators/ranges,
security limits, and fallback semantics. New helper APIs include
`parse_accept_encoding`, `directory_listing`, `directory_redirect`, and the low-level
asynchronous `open_static_file`/`list_file_directory`/`take_directory_listing`.


## E9.S1 optional outbound transport

Import `silly_client` from the separate `client` package to opt into libcurl linkage.
`start_client(ClientOptions)` creates the single process-wide bounded pool; `submit`
copies a GET URL into a native-owned request and returns an epoch/token handle.
`snapshot`, `read` and `headers` inspect/copy retained response state. `cancel` requests
cancellation; `release` accepts only terminal requests. `wake_descriptor`/`drain_wake`
allow the existing runtime poll set to observe progress without polling curl on an
I/O owner. Drain notifications before inspecting all tracked request snapshots.

`stop_client` closes admission and cancels live requests; `finish_client` reports
incomplete until native cleanup has finished, retaining ownership meanwhile. TLS
certificate and hostname verification are mandatory. HTTP/1.1 pause/resume, finite
connection/queue/header/body limits and queue/connect/first-byte/idle deadlines remain
active even when the optional total timeout is disabled. See
[client transport](client.md) for exact defaults, handle lifetime and runtime integration.


## E9.S2 client request and response APIs

`submit_request(client, url, RequestOptions)` supports arbitrary token methods,
ordered duplicate request headers, copied binary bodies and incremental uploads.
`ClientBodyMode.Buffered` copies up to 65536 bytes; `Stream` exposes a 16384-byte
pending window through `write_upload` and explicit `finish_upload`. Declared lengths
are enforced; unknown lengths use chunked transfer. Framing headers belong to the
adapter. `ClientOptions` separately bounds total request header/body bytes.

`response(request)` returns an owned final `ClientResponse` with status, interim count,
bodyless/redirect classification and up to 128 ordered fields. `response_header`,
`get_header` and `content_type` return views borrowed from that response owner.
Transfer framing fields are removed. Raw content decoding preserves compressed bytes;
automatic gzip/deflate decoding removes stale content encoding/length metadata and
caps decoded output. HEAD/304 representation metadata remains available.

`collect` optionally accumulates bytes under a caller cap with a finite per-call work
budget; it requests cancellation on overflow and leaves release ownership with the
caller. `redirect_url` resolves Location without network activity; `follow_redirect`
requires an explicitly approved target and fresh options, preserves no credentials
or body implicitly, and applies a finite hop cap. Exact contracts and examples are in
[client transport](client.md).


## E9.S3 streaming proxy APIs

Explicitly import the optional `proxy` module alongside the client and core packages.
It exposes `ProxyOptions`, `ProxyTransfer`, `proxy_response`,
`proxy_step` and `proxy_step_with_policy`. Applications select the target URL, forwarding
policy and optional bounded inspection. `proxy_target` preserves raw query ordering;
`forward_request_headers` and `forward_response_headers` provide bounded ordered fields
with hop-by-hop and Connection-nominated fields removed. Authorization and Host have
explicit policy enums. `ProxyFailure`/`ProxyErrorResponse` map precommit errors;
`ProxyInspection` supports audit/status policy before response publication. Errors after the first wire write
terminate the stream without replacing its response. `abandon` transfers live request
cleanup to the native worker without requiring a later release callback.

Core `StreamStart.duplex` opts into input/timer callbacks while output remains pending.
Such callbacks receive a zero-length writer with no metadata pointer and may only
return `Wait` or `Failed`. `Wake.InputAfter {delay_ms}` combines immediate input demand
with a Ready timer. Ordinary streams retain their original acknowledgement-before-next-
callback contract. Deferred `StreamMetadata` owns bounded generic header fields/bytes,
`replace_headers` and `close`; shared response validation and framing remain authoritative.
`ChunkWriter.failure` borrows an owned `StreamFailureResponse` only before wire commitment,
including zero-output duplex callbacks. Set `selected`, `status`, `content_type` and
`body`, then return `Failed` to request a mapped response through the shared writer.
The pointer is null after commitment and during cancellation. Limits and response
policy still apply; invalid or oversized mapped responses fall back to the standard 500.
See [client composition](client.md#proxy-composition) and the executable
[Portal reference](../reference/files_and_portal.goose).

## E9.S4 consumer policy examples

[Portal/MCP outbound contracts](promptnook_outbound.md) document ordinary modules under
`examples/promptnook_contract`, source-derived policy fixtures, local HTTP/HTTPS checks,
and bounded audit facts. `suppress_default_accept` on client/proxy options expresses
missing Accept independently of an explicitly empty field. No consumer configuration,
credential lookup, audit logger or business route is installed by the framework.
