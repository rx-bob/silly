# Server-sent events

`events(ctx, owned_state, SseOptions)` selects a 200 streaming response with
`Content-Type: text/event-stream` and configurable `Cache-Control` (default `no-cache`).
`SseOptions.pending_bytes_max` selects the existing 1–4096 byte retained-chunk capacity.
Response metadata is validated before producer state transfers to the owner. On failure,
the caller still owns handles in the proposed state. Connection framing and persistence
remain transport policy; the helper never injects a reserved Connection header.

`SseEvent` carries `data`, `event`, `id`, `retry_ms`, `data_present`, and `id_present`.
Call `sse_event(ChunkWriter&, SseEvent)` from a short producer step. It returns false
for invalid fields or insufficient capacity without exposing a partial frame. Every
accepted event ends with a blank line. Field order is event, id, retry, then data.

- Data defaults to present and empty, producing an empty data event. Set
  `data_present: false` for an ID/retry-only update without a dispatched message.
- Empty event names are omitted, leaving the browser's default message type.
- Nonempty IDs are emitted automatically. `id_present: true` also emits an empty ID,
  which resets the client's last event ID.
- `retry_ms: -1` omits retry; nonnegative integers emit decimal milliseconds.
- `sse_comment(out, text)` emits a comment block suitable for a heartbeat.

All text must be valid UTF-8. Event names and IDs reject CR, LF and NUL. Data and
comments split CRLF, bare CR and LF into logical lines, prefix every line, and preserve
trailing empty lines. A payload containing `id:` or `event:` therefore remains data,
not a new field. The helpers follow the [WHATWG event stream format](https://html.spec.whatwg.org/multipage/server-sent-events.html#parsing-an-event-stream);
rejecting NUL in event names is an additional API validation rule.

Return `StreamStep.Chunk { flush: true, next: Wake.After { delay_ms: ... } }` to
request progress and the next application-selected heartbeat time. Flush does not
promise synchronous delivery. Pending output prevents further producer calls even
when the timer expires; acknowledgement permits the next eligible step. No timer
thread or event queue is created per client. Disconnect/shutdown cancellation sends
one zero-capacity Cancelled callback and prevents future timer work. Normal Done
requires the producer to release its own resources before returning.

`header(ctx, "Last-Event-ID")` is ordinary borrowed request metadata. Copy it into
bounded owned state if needed after the handler returns. Silly does not store event
history, replay events, or infer a resume policy.

Build `examples/events.goose` and connect an SSE client to `http://127.0.0.1:8085/events`.
The finite source copies a bounded Last-Event-ID, emits an initial comment, five tick
events and interleaved heartbeat comments, then releases its owned state. Cancelling
the client takes the same explicit cleanup path. `reference/streaming.goose` runs the
shared example on port 8083 through the production six-argument serve contract.

Verification on macOS: formatter tables, metadata ownership, controlled-clock scheduler
and real-socket SSE tests pass debug and optimized builds. Capacity rejection leaves
writer bytes unchanged; malformed fields cannot introduce new lines. A live run of the
shared example verified five events, four heartbeats, Last-Event-ID and response headers.
