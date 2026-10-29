# Streamed HTTP input and output

Declare an inline route with `RouteOptions { body: BodyMode.Streamed, .. }` and
select `stream_input(ctx, status, owned_state, StreamOptions)` in its handler.
The handler runs after validated headers, before collecting the body. Its body view
is `RequestBody.Streamed`; buffered extractors report unavailable. The six-argument
`serve<R,A,S>` overload owns the decoder and producer on the same listening owner.
Buffered-only owners reject streamed routes; execution lanes do not accept them.

The producer first receives Ready and requests `Wake.Input`. Each subsequent Input
contains a callback-local decoded slice. Copy into the bounded writer or owned state
before returning. Input is decoded only when requested and no output chunk remains
pending. If the final decoder call produces bytes, Input precedes InputEnd; output
must drain before that next event. InputEnd occurs once. No request-sized array is
allocated, and HTTP chunk boundaries need not match Input or output chunk boundaries.

`body_limits.bytes_max` limits the total decoded streamed request. A nonnegative route
`body_bytes_max` can lower that limit. `limits.body_bytes_max` controls buffered request
storage and may be zero for streamed routes. Chunk metadata, trailers and chunk counts
retain independent finite limits. `body_read_bytes_max` bounds socket staging;
`StreamOptions.pending_bytes_max` bounds each producer output and input delivery chunk.
All storage is reused across steps instead of growing with total transfer length.

Malformed framing, decoded limits, truncated input, disconnect and timeout terminate
input/output ownership. A precommit error may produce an ordinary error response;
a committed response closes without a second response or successful chunk terminator.
Producers receive terminal cleanup exactly once. A producer cannot turn malformed
input into a successful response by ignoring InputFailed.

HTTP/1.1 streaming emits size/payload/CRLF chunks and exactly one final zero chunk on
success. Payload storage remains retained through its framing suffix. HTTP/1.0 streams
close to delimit output, including requests that asked for keep-alive. HEAD and
204/205/304 suppress producer output and clean selected state without data callbacks;
205 has zero Content-Length. No-body responses do not emit a chunk terminator.

A connection is reusable only after the request decoder completes and the final
response framing drains. Decoder consumption preserves any pipelined request tail.
If the handler replies without consuming streamed input, or the producer finishes
early, the connection closes. Expect: 100-continue is validated before the interim
response; producer dispatch follows its completed write and does not wait for a new
socket-read event.

`reference/request_stream.goose` is a runnable byte-preserving upload/download example
with zero buffered-request storage, an 8 MiB decoded limit and 1024-byte pending chunks.
`tests/streaming/stream_http_test.goose` exercises generated input without total-body buffers;
`tests/streaming/stream_framing_test.goose` checks persistent bodyless boundaries and HTTP/1.0.

The absolute body deadline and idle deadline are checked before an input callback;
a late final body chunk cannot erase an expired deadline. Input-created output starts
a fresh write budget. A hangup does not discard valid staged bytes; the decoder
resolves EOF and output writes detect failed peers. During an explicit producer timer
wait with no requested I/O, the descriptor is omitted from polling to avoid hangup
spinning; renewed demand or the finite idle/body deadline resolves disconnection.

Verification on macOS: streamed HTTP, body timeout, controlled-clock and output framing
suites pass debug/optimized builds. Buffered-body, persistence and worker-runtime
regressions pass. The public reference echoed 256 KiB byte-for-byte with zero buffered
request storage and bounded client read/write chunks.
