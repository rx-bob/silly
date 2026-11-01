# Silly package and architecture contract

The implemented package provides bounded request/header views, typed prepared routing,
response phases, lifecycle scheduling, serialized native work, streams, rooted files
and the optional outbound client/proxy. The sections below retain story-by-story
architecture evidence; early E1/E2 descriptions are implementation history rather
than a claim that later capabilities are missing. Start with the current
[README](../README.md), [handlers](handlers.md) and [streaming](streaming.md) guides.

## Package boundary and verification

`silly.goose` is the library root; it does not own `main`. A consumer root imports
`silly from "path/to/silly"`. `tests/support/consumer_import.goose` is a separate executable
using the normal relative package import, not a project-module import. `silly.build`
declares `native/transport.c`, `native/files.c` and `native/control.c`. No PromptNook, Turso, bcrypt, zlib,
libcurl, application startup, or PoC module is imported or linked by this package.
E1.S3 adds the core OS transport; E9.S1 introduces a separate optional client package.

Run from the repository root:

```text
goose check tests/support/consumer_import.goose
goose build tests/support/consumer_import.goose --offline -O2 -o /tmp/silly-consumer-release
/tmp/silly-consumer-release
goose build tests/support/consumer_import.goose --offline -O0 --debug -o /tmp/silly-consumer-debug
/tmp/silly-consumer-debug
/Users/bob/repos/goosefmt/goosefmt check --config .goosefmt.toml silly.goose tests reference
goose build reference/dispatch_proof.goose --offline -o /tmp/silly-dispatch-proof
/tmp/silly-dispatch-proof
```

Validated on macOS arm64 with Goose runtime `4d3da949e563` (installed v2026.3)
and Apple clang 17.0.0. Both consumer builds run and print `silly package import passed`.
The dispatch proof checks static callbacks, typed route selection, and named endpoint
guard return. It is not an HTTP server, lifetime suite, or suspension proof.
Linux is an initial target, but was not exercised in this E1.S1 workspace.
E1.S2 verification and compiler lifetime fixtures are documented in the core contracts.

## Sources of authority

- [Public API contract](public_api.md): signatures, ownership, failures and owning
  implementation stories for the reference operations.
- [Consumer requirements](promptnook_requirements.md): observed application scope,
  source identity, native boundaries and responsible stories.
- `reference/app.goose`, `promptnook.goose`, `responses.goose`,
  `files_and_portal.goose`, `streaming.goose`, and `request_stream.goose` are preserved
  design sketches. They intentionally cannot compile until their owning stories land;
  `application::` represents consumer code, not a missing framework subsystem.
- `reference/dispatch_proof.goose` is independently runnable language evidence.
- `poc/` remains unchanged historical evidence. Its request-time route chain and
  implicit response/body conventions are not the public contract.

Any compiler-driven API revision must update the contract, affected reference and
story verification together. Do not make the sketches compile with mock server APIs.

## Protocol and platform scope

Initial platforms are Linux and macOS. Incoming HTTP/1.1 and HTTP/1.0 compatibility
use external TLS termination. Outbound HTTP and HTTPS use the optional libcurl multi
adapter; the core package must remain usable without that dependency. Separate API
and Portal listeners, graceful cancellation and bounded drain belong to the runtime.
No HTTP/2, HTTP/3, inbound TLS implementation, WebSockets or multipart upload parser
are in this plan. Framework work does not port, deploy or publish PromptNook.

## Ownership and execution

Startup prepares typed `Router<R>` declarations and immutable method/path lookup.
Registration may replay per owner during preparation, never per request. Named static
callbacks receive the selected route; ordinary enum dispatch invokes application
handlers. No runtime function storage or escaping trailing blocks are required.

The driver owns request bytes, response builders, scratch buffers and transport state
separately. `Context<A, S>` borrows those owners for one endpoint invocation. Retained
head/body views expire before their root storage resets. Transformed extraction uses
explicit scratch; unchanged values may borrow input. Pool references use offsets and
generation IDs so reused slots cannot masquerade as old requests.

Buffered helpers copy payloads once into bounded response-owned output. Direct
serializers append into that output. File, proxy and stream operations own their
retained sources until transport acknowledges consumption. Header and body buffers
remain separate. These contracts make no unmeasured zero-copy or throughput claim.

Response selection and commitment are separate. Missing response, intentional empty
response and duplicate response are distinct outcomes. Prepared metadata is mutable;
commit freezes status and headers. Later errors cancel/close rather than create a
second response. Handler completion occurs after the endpoint boundary; transfer
completion occurs only after drain or cancellation. Each terminal event and resource
release occurs once, before reuse.

Each I/O worker owns its event loop and bounded connection pool. Stream producers
return fixed-size owned state and explicit steps; no handler frame survives return.
Readiness, finite timers or requested input trigger bounded work. Messages crossing
queues are flat, owned, bounded and tagged with owner/request/connection generations.

Application state is owner-local. PromptNook's C database and ZIP globals require
one process-wide serialized execution lane, including native initialization and
cleanup hooks. Goose thread isolation does not isolate C statics. Parallel lanes
require reentrant caller-owned native state. Contained aborts do not close foreign
descriptors; noncooperative native calls cannot promise deadline-bounded termination.

Goose owns HTTP parsing, routing and policy. A single canonical FFI module owns each
native interface. C handles descriptors/readiness/files and the outbound library.
No native call retains a borrowed Goose pointer beyond its documented lifetime.
Business authorization, sessions, database operations, ZIP generation, audit schema,
environment selection, migrations, seeding and reset behavior remain in PromptNook.

## Mandatory style and resource contract

The normative guide is
[/Users/bob/repos/goosefmt/docs/styleguide.md](/Users/bob/repos/goosefmt/docs/styleguide.md).
`.goosefmt.toml` copies that repository's configuration. Use its repository formatter;
the older PATH formatter does not support all configured rules. Historical PoC files
are excluded from formatting edits. Newly shipped code and reference files are checked.

- Focused namespaced files under 500 lines; functions at most 70 lines; lines at most
  120 columns; four spaces; one statement per line; at most six parameters/three returns.
- File header, namespace, direct grouped/sorted imports, constants, types, FFI, public
  callers then helpers, executable entry point. Import every dependency directly.
- Ordinary slice parameters use const-generic `u8[:]`; stored/FFI read-only views use
  `const`. Bind references with `.=`; independent non-fixed copies require `copy`.
- At most one owned resizable tail per struct. Return fresh values by value; incremental
  output appends to a leading writer. Keep separate growable owners in driver locals.
- Validate named caps for heads, fields, paths/captures, body/output/chunks, ranges,
  directories, connections, queues, deadlines and scheduler work before accepting input.
  Reset each allocation class only after its borrows and transport ownership end.
- Operating errors return explicit outcomes. Assertions express internal invariants,
  not malformed-input policy. Separate coordinators from direct-slice kernels; inspect
  `--stacks` and `--bce-lines` on relevant kernels and prove any `checkfree` annotation.
- Repository automation belongs in Goose. Each story gates on formatting, typechecking,
  optimized/debug compilation and its behavior-specific functional tests. No benchmark,
  telemetry, rollout or generic smoke-check infrastructure is introduced.

E1.S4's [continuation and mailbox gate](continuations.md) now proves the static callback
shapes, reusable state and completion ownership. Production scheduling remains in E6/E7.

E2.S1 now supplies [bounded incremental request-head parsing](http_heads.md), strict
framing validation and retained trailing bytes.

E3.S1 now provides [immutable route preparation and static dispatch](routing.md).

E4.S1 adds [indexed, exact and repeated header access](request_headers.md).

E2.S2 provides [bounded fixed-length/chunked body readers and server collection](request_bodies.md).

E2.S3 adds [response framing, separate wire segments and precommit error rendering](response_wire.md).

E3.S2 adds scoped method-policy snapshots, borrowed compiled capture views, and early
generated method replies through the bounded response writer. Matching remains a bounded
scan; Allow uses bounded repeated selection without temporary route arrays.

E3.S3 adds a statically checked endpoint guard boundary, typed borrowed application
state and once-per-handler cleanup. See [endpoint contracts](endpoint.md).

E4.S2 adds [bounded URL/query/form decoding](url_query_forms.md), retaining raw views
and growing caller-owned scratch only after complete input preflight.

E4.S3 adds [borrowed JSON views, explicit typed binding and bounded composable output](json.md).

E2.S4 adds [sequential HTTP persistence and classified early errors](connections.md).

E5.S1 adds [bounded HTML and buffered response helpers](responses.md), with a runnable escaped form workflow.

E5.S2 adds [static middleware and owned handler/transport lifecycle records](middleware.md).

E5.S3 adds [bounded CORS and scoped response/error policies](cors.md).

Next story: **E7.S1 — Implement explicit streaming producers and retained chunk ownership**.

E6.S1 adds [bounded independent I/O workers](runtime.md): a supervisor transfers accepted
sockets through addressed queues to private connection pools, app owners and immutable
route plans. `run_runtime` takes a concrete application `thread_fn` bridge because Goose
thread entrypoints cannot be generic. Existing `serve` remains single-owner.

E6.S2 adds [bounded executor lanes](executors.md): flat owned request snapshots, static
lane queues, addressed replies, owner-credit conservation through cancellation, and
four-part generation checks before reply application. Shutdown closes admission before draining and joins every producer before closing
notification descriptors. Native calls remain cooperative.

E6.S4 adds [phase deadlines and resumable shutdown](shutdown.md), explicit signal
adapters, shared API/Portal listeners, and contained worker-failure reporting.

### E7.S1 completion

Owned producer scheduling and the six-argument typed serve overload now run in the
single-owner socket loop. Configured chunk capacity, transport acknowledgement, timer
eligibility, explicit commitment, stale-key rejection and terminal cleanup are checked.
Real socket fixtures cover short writes, both HTTP output versions, producer failures,
disconnect/shutdown cleanup and slow-reader pause/resume. See [streams](streams.md).
Next story: **E7.S2 — Connect request-body streams and transport framing**.

### E7.S2 completion

The same typed producer now consumes incremental fixed/chunked request bodies. Exact
decoder consumption preserves pipelined tails; input demand and pending output enforce
backpressure. Reuse requires complete input and final response framing; early replies
close. Bodyless and both HTTP output versions have real-socket coverage. See
[streamed HTTP](streamed_http.md). Next: **E7.S3 — Provide SSE formatting and a cancellable event example**.

### E7.S3 completion

SSE formatting and metadata reuse the retained-chunk scheduler. Field validation,
multiline data/comments, explicit ID reset/retry, finite heartbeat production and
cancellation have formatter, controlled-clock and socket coverage. Metadata failure
leaves proposed producer state with the caller. See [SSE](sse.md).
Next story: **E8.S1 — Serve safe rooted files and opaque binary attachments**.

### E8.S1 completion

A dedicated bounded filesystem executor performs descriptor-based rooted opens,
metadata checks and incremental reads. Generation-checked tokens keep files on their
workers through cancellation, while retained stream chunks gate subsequent reads.
Native adversarial tests cover path traversal, symlink races and blocked-read cleanup;
loopback fixtures cover binary/ZIP bytes, bounds, short writes and terminal cleanup.
Next: **E8.S2 — Implement MIME types, HEAD, validators and conditional requests**.


### E8.S2 completion

Static responses defer header preparation until the asynchronous open publishes its
immutable descriptor metadata. Bounded owned fields retain application headers and
request conditions; the shared writer then selects fixed-length GET, HEAD or 304.
MIME overrides and a static application ETag hook share the normal file producer.
See [files](files.md) for caps, conditional precedence and ownership.
Next: **E8.S3 — Add bounded file ranges**.


### E8.S3 completion

Opened-file metadata drives bounded range selection after conditional validation.
A fixed array retains at most 16 ordered ranges; a single framing segment alternates
with asynchronous file reads through the existing backpressure protocol. Deferred
headers select single-range 206, multipart 206, unsatisfiable 416 or full 200, including
exact bounded framing lengths. HEAD ignores Range and cancels before body reads.
Strong If-Range checks prevent partial retrieval after validator mismatch; date
strength requires an explicit application guarantee. See [files](files.md) for
limits and the deliberate Portal multipart-media-type and HEAD-body corrections.
Next: **E8.S4 — Support precompressed files and application-selected directory/fallback behavior**.


### Static mount ownership (E8.S4)

A typed route selects `StaticTransfer` through `static_mount_response`; this revises
the proposed opaque `router.files` action to use the implemented explicit handler
and static-producer model. `FileMount` contains application-owned root/executor
handles and finite policy caps. No filesystem path or callback frame is borrowed
after handler return.

The native file executor admits a static lookup that may return a regular file,
a directory, or a classified failure. It selects a fresh `.gz` sibling on the
worker before publishing descriptor metadata. The stream owner then invokes a
static policy callback for directories/failures or delegates to `FileTransfer` for
the selected file. Conditional evaluation and range selection therefore describe
the actual encoded bytes. Deferred metadata owns Content-Encoding, Vary and redirect
Location through the shared response writer.

Directory enumeration is a bounded worker job on the validated directory handle.
Packed names are copied only after completion, sorted and rendered under an explicit
output cap, then streamed from owned bounded state. Explicit replacement-path policy
uses a finite hop count. Cancellation marks pending jobs and defers descriptor close
to their worker completion; application shutdown retains executor ownership until
finish reports completion.


## E9.S1 optional client owner

`client/client.goose` is an independently imported package. Its sidecar compiles
`client/native/client.c` (one compiled source for reliable native cache invalidation) and links libcurl plus zlib; core server
imports do not traverse or link that package. An optimized core consumer was run and
its macOS dynamic dependencies contained only libSystem, with no libcurl dependency.

One native worker owns a libcurl multi handle and a fixed pool of at most 64 native
request slots. Goose retains epoch/token handles only. Admission copies bounded URL
and trust configuration; callbacks write bounded native header/body storage and pause
upstream when the body stage is occupied. HTTP/1.1 avoids multiplexed paused-stream
buffering. Easy-handle completion retains the multi connection cache for eligible
reuse. Application consumers can copy body bytes in arbitrarily small pieces without
retaining callback or handler-stack borrows.

A borrowed notification descriptor joins the existing runtime poll set. The consumer
drains the wake pipe before checking every tracked request, because notifications
coalesce. The worker's multi poll is woken by submissions, consumption and cancellation,
and bounded by curl timers plus the nearest application deadline. Network callbacks,
resolver cleanup and TLS work execute on the native owner, outside the API-copy mutex.

Stop closes admission and requests cancellation; successful finish alone releases the
worker, descriptors and pool epoch. An incomplete finish retains ownership. As with
other native owners, the caller must serialize successful teardown against use of its
borrowed wake descriptor. TLS checks cannot be disabled; unsupported non-asynchronous
DNS builds fail startup. The exact E9.S1 API, limits and tested platform are in
[client transport](client.md).


## E9.S2 duplex client state and response metadata

Each native request owns its method, copied ordered headers and upload bytes.
Buffered uploads admit at most 65536 bytes; streaming admits a separate logical
16384-byte window and an explicit EOF/declared-length contract. Curl read callbacks
pause the send side when producer capacity is absent. Receive callbacks independently
pause the response side. Only the native owner changes curl's combined pause mask;
resuming one direction retains the other's state, including synchronous replay during
an unpause call. Upload activity uses the idle deadline before entering response wait.

Header callbacks delimit response blocks by status lines and blank terminators.
Interim blocks and trailers count against cumulative header limits, but only the final
complete block becomes the public response metadata. Goose copies that block into a
bounded owned response, preserving duplicate order and optional lookups. Raw headers
remain distinct from the normalized body view: transfer framing is always removed;
actual content decoding also invalidates compressed encoding/length fields. Bodyless
HEAD/304 metadata is preserved. Content decompression uses an owned incremental zlib decoder after curl's transfer
decoding, with separate fixed 16384-byte compressed and decoded stages. EOF requires
valid decoder completion/integrity; truncated trailers cannot silently succeed.
Decoded bytes count against the total response output cap.

Redirect resolution performs no transfer. Following a redirect is a fresh explicitly
approved admission with a hop cap and no inherited header/body state. This keeps target,
Authorization/Host selection and stream replay in application policy. Bounded collect
is a consumer of the same incremental read API; exceeding its cap requests cancellation
without taking over request release or shutdown ownership.


## E9.S3 bidirectional proxy composition

The optional client composes with the server continuation driver through an owned
`ProxyTransfer`. Handler admission copies the selected upstream URL and header policy;
no request/context borrow survives. The server incrementally decodes inbound body
framing, and the proxy owns at most one 4096-byte upload residual while the native
upload window is full. Response bytes flow from the bounded native stage into one
server output chunk. Optional whole-body inspection is explicit and capped at 32768
bytes; streaming is the default.

`Wake.InputAfter` expresses input demand and upstream polling together. Duplex streams
may run housekeeping while a downstream chunk is pending, but their writer has zero
capacity and no metadata pointer. Only Wait/Failed is valid, preserving the original
chunk and acknowledgement cursor. Input EOF and native timeout/failure observation do
not wait for a slow downstream reader. The existing server deadlines and per-turn
budgets still apply. The proxy polls retained client state on bounded server timers;
it does not drive curl or install per-request worker threads.

Final response metadata remains deferred until inspection/policy succeeds. Owned generic
headers pass through the shared response writer and configured limits. Forwarding drops
hop-by-hop fields, Connection nominations and obsolete framing/decoding metadata;
application choices govern target, Authorization, Host and status mapping. An independent owned failure-response slot remains writable by producer callbacks until
the first wire write, including while a chunk is pending. Returning Failed selects that
bounded response through the shared buffered writer, preserving application mapping in
the metadata-selected but not-yet-committed window. After commitment its callback pointer
is null and upstream failures only terminate the stream.
An unfinished inbound body marks early responses Connection: close.

Cancellation calls native `abandon`: the Goose handle is invalidated while active native
owners remain with the worker until curl/decoder cleanup finishes. The slot becomes
reusable only after that cleanup; epoch/token identity rejects old handles. This allows
the server's exactly-once cancellation callback to release request ownership without
keeping a dead connection around to poll cancellation completion.
