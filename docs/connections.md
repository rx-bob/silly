# Connection persistence and early errors

E2.S4 makes buffered HTTP requests persistent. HTTP/1.1 reuses connections by default;
HTTP/1.0 requires a `keep-alive` Connection token. Comma-separated and repeated Connection
fields are case-insensitive. `close` wins over `keep-alive` across all fields. Invalid
token syntax disables reuse; empty list elements are ignored. The wire writer emits
`Connection: keep-alive` for persistent HTTP/1.0 and `Connection: close` when closing.

## Bounded sequential processing

Each connection has separate, nonmoving slabs for head input, body input, socket staging,
response head and response payload. A socket read fills staging only after previous bytes
are consumed. Head parsing copies only up to the head cap and retains everything after
the terminator in staging. Body decoding consumes exactly its framing; later request bytes
remain queued. Staging may be larger than the head slab without overflowing it.

Queued bytes count against the existing `min(body_read_bytes_max, work_bytes_per_turn)`
staging allocation and `buffer_bytes_max`. The server does not read ahead while writing a
response. Further input stays subject to socket backpressure; no unbounded request queue
or concurrent pipelined handler dispatch is introduced.

A final response must completely finish writing before the next request is parsed and
handled. Request/handler/renderer borrows have ended before reset. Only descriptor,
generation, activity time and unread staging offsets survive; method/header views, captures,
body decoder, response status, metadata, payload lengths and send cursors are rebuilt.
The response framing plan can also require close. Queued bytes trigger immediate service
without waiting for new socket readability, including bytes already read with a prior body.

## Unread bodies and early replies

Buffered application handlers run only after the full bounded body has been decoded.
An auth guard or early application response may therefore reuse the connection: unread
application-level body bytes cannot become another request. No handler reads partial body
storage, and no implicit drain runs after a handler returns.

Generated OPTIONS/405 replies happen before `100 Continue`. They can reuse a bodyless
request, but a chunked or positive-length body forces close without draining. Route admission,
unsupported expectations, body limits and parser failures likewise render then close.
Ambiguous framing always closes; bytes following a rejected body never dispatch.
Closing with unread kernel input can cause a TCP reset and truncate response delivery;
this server does not add a lingering drain for input sent after a close request.

## Error rendering and transport boundaries

The configured `ResponseFailure` renderer now receives `RequestHead`, `RequestBody`,
`Admission` and `Timeout` kinds, in addition to application/serialization failures.
`head_error` and `body_error` carry typed parser outcomes. `transport_status` identifies
input EOF (`Closed`) when truncation is reported; `system_error` is reserved transport
metadata. Parser failures may leave `error == ResponseError.None`: inspect `kind` and
the corresponding parser field, not only the response-builder error.

These errors use fresh response owners and force close even if the renderer changes the
status or payload. A valid request line preserves HTTP version and HEAD response semantics.
Before a valid request line exists, errors use HTTP/1.1. Renderer failure falls back once
to an empty 500/close response, without recursive rendering.

EOF with no partial request closes quietly. EOF during a head or body may render 400
truncation while the peer's read side is still open. Inactivity during partial input may
render 408; idle keep-alive connections close quietly. A final response already in progress,
a blocked interim response, or a fatal socket read/write failure closes directly: the
server cannot safely emit a second envelope. No renderer is invoked for fatal transport
errors where write safety is unknown. Idle timeout also bounds attempts to send errors.

See `tests/http_connection_test.goose` for persistence and reset contracts and existing
HTTP head/body/response socket fixtures for malformed input and explicit-close behavior.
`tests/http_connection_errors_test.goose` checks half-close truncation, partial-input
timeouts, quiet idle close and renderer fallback.
