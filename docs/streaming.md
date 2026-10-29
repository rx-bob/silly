# Streams, files and proxy ownership

Use the public typed streaming server when an endpoint needs a response producer,
incremental request input, SSE, a file or an upstream proxy. Complete examples are
[request_stream.goose](../reference/request_stream.goose),
[streaming.goose](../reference/streaming.goose), and
[files_and_portal.goose](../reference/files_and_portal.goose). The
[combined general-web test](../tests/integration/general_web/general_web_test.goose) exercises the general web
response/input shapes through real loopback transport.

## State survives; borrowed views do not

`ctx.stream` or `ctx.stream_input` selects owned `StreamState`, copied response
metadata and bounded pending-output settings. The handler then returns. The owner
calls the static `step(state, event, out)` function later; no handler stack or runtime
closure survives. A state must contain owned values/handles, never borrowed request
headers, captures, body slices, input chunks or scratch buffers.

Events are `Ready`, `Input`, `InputEnd`, `InputFailed` and `Cancelled`. `Input.bytes`
is borrowed only for that step. `ChunkWriter` exposes finite output space; check
`append`/write results before returning. The owner retains produced bytes until the
transport drains them, then resumes production. Slow clients cannot create an
unbounded sequence of completed chunks.

Return `StreamStep.Chunk` with the next wake request, `Wait`, `Done`, or a typed
`Failed`. Wake choices request input, timers or readiness rather than busy polling.
The framework reads input only when the consumer requests it. A bounded producer
must retain progress across partial writes and avoid repeating side effects when
called again. `Wake.InputAfter` and explicit duplex stream selection let the proxy
advance upload input while a zero-output response step waits on its upstream.

## Input framing and caps

Declare `RouteOptions { body: BodyMode.Streamed, body_bytes_max: ... }` on the route.
The route body cap is separate from `Limits.body_bytes_max` buffered storage, so a
stream-only server may use zero buffered-body storage with a positive streamed cap.
`BodyLimits` also bounds decoding/trailers/work, and `body_read_bytes_max` limits a
single read step. Fixed-length and chunked input is decoded before `Input` events.
Invalid framing, truncation, oversize input and disconnect become explicit failures.
An oversized declaration can reject before a 100-continue interim response.

A producer that needs a final response only after consuming the request can defer
wire commitment. Do not assume selecting a stream means headers are already on the
wire. `InputEnd` is the successful end of decoded input; `InputFailed` is not a
successful empty body. The [echo reference](../reference/request_stream.goose) copies
each input chunk into bounded output without retaining the borrowed input slice.

## Commitment, cancellation and completion

Before commitment, stream metadata and an explicitly owned failure response can
select status/headers/body through the common writer. The failure-response slot is
available only while replacement is legal. After commitment, failure terminates the
transfer without a second status line or successful final chunk.

`Cancelled` releases each owned resource exactly once. A native syscall or foreign
callback may still own its handle after cancellation; the I/O owner must not close
and reuse that handle prematurely. Terminal producer cleanup and lifecycle reporting
are separate: `HandlerFinished` means selection completed, whereas `TransferFinished`
reports the transport outcome. Never log handler completion as delivery success.

SSE uses the same bounded stream mechanism. The event helper formats complete events
and enforces event/field limits; heartbeat timers and Last-Event-ID are application
policy. Completion, cancellation and header/body rules remain ordinary stream rules.
The runnable reference delegates to the implemented
[events example](../examples/events_routes.goose), not a special SSE transport.

## Files and static mounts

Open a trusted root and start a bounded `FileExecutor` during application startup.
Descriptor-relative path walks reject symlinks/traversal; accepted file jobs pin
ownership until native work finishes. Filesystem work runs off the I/O owner.
`file_response` transfers an `OwnedFile` only on successful selection; if selection
fails, the caller still closes it. `StaticTransfer` adds deferred metadata, validators,
ranges, directory policies and representation-aware gzip selection.

A file producer has at most one pending read per transfer and sends bounded chunks.
If a file truncates after commitment, the transfer fails rather than claiming a
complete body. Stop executor admission, request cancellation, then retain its handle
until `finish_file_executor` reports completion. Root lifetime must be coordinated
with admission; copied handles are not independent ownership. See
[files](files.md) for exact limits, path policy and HTTP corrections.

## Optional client and proxy

Import `client` and `proxy` explicitly from the optional client package. Start one
bounded client pool and retain it until all owned requests have finished or been
abandoned and pool shutdown completes. Admission copies URL/header/body inputs;
foreign callbacks never retain Goose request/context pointers. Client request tokens
include epochs to reject stale operations. HTTP/HTTPS transport uses libcurl directly,
not a curl subprocess; TLS verification remains enabled.

The proxy owns a `ProxyTransfer` and composes incremental request upload with response
production. It filters hop-by-hop/Connection-nominated headers, selects explicit Host
and Authorization policies, and rebuilds downstream framing. Source-derived Portal
URL/query/auth/error policy lives in application-local helpers. Optional bounded
inspection is explicit; normal forwarding does not buffer the whole response.
Cancellation abandons the upstream operation and retains worker ownership until
cleanup is safe. See [client](client.md) and
[outbound consumer contracts](promptnook_outbound.md).

## Composition and later application port

The buffered worker runtime supports multiple listeners and serialized blocking lanes;
stream-capable servers use the typed streaming serve APIs. The integrated consumer
example runs the API/native runtime and a separate streamed Portal instance in the
same process. A gated native DB sequence does not block Portal file/proxy work.
This is a supported public composition, not an assumed runtime-stream overload.

The later PromptNook port supplies real archive creation, stores, credentials,
upstream configuration and audit schemas. Retain the one serialized owner for current
C globals, choose finite file/client/input/output limits, keep resources alive through
cooperative shutdown, and interpret completion facts in application code. The
[migration matrix](migration_notes.md) records every deliberate protocol/resource
change; these examples perform no business port or production deployment.
