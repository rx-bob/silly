# Owned streaming producers

`serve<R, A, S>(options, app, routes, handle, step, lifecycle)` binds every callback
statically. The handler selects an owned fixed-size `S`; after the handler returns,
the connection owner calls `step(S&, StreamEvent, ChunkWriter&) -> StreamStep`.
No callback frame, request view, or writer borrow is stored between turns.
Selection succeeds only when `stream` returns `ResponseError.None`; on rejection,
the caller still owns any resource handles passed in the proposed state.

The typed overload uses the existing single listening execution owner.
`run_prepared_stream_server<R,A,S>` additionally accepts an owned listener and wake
reader; a wake cancels producers before transfer notifications and Stop. This is the
single-owner cancellation API, not E6 runtime graceful-drain handles. Buffered and
streamed responses can share its routes. HTTP/1.1 output uses chunked framing;
HTTP/1.0 output closes at completion. SSE formatting remains E7.S3.

## Bounded scheduling

`StreamProducer<S>` contains a `Continuation<S>` and one physical 4096-byte chunk.
`StreamLimits.pending_bytes_max` selects a usable capacity from 1 through 4096.
Only one chunk may be pending. There is no unbounded list or allocation proportional
to total output. The producer can reuse its state/output storage only after the
transport acknowledges the entire pending chunk. Arbitrary partial acknowledgements,
zero-byte progress, and would-block leave the remaining bytes stable.

Each eligible scheduler call invokes at most one producer step:

- `Chunk { flush, next }`: positive bounded bytes become retained pending output.
  `flush` requests prompt transport progress, never synchronous delivery. Output
  always requests commitment and progress, including when `flush` is false, because
  the one-chunk capacity is exhausted until acknowledgement.
- `Wait { wake }`: no bytes; yield until the requested event is eligible.
- `Done`: no bytes; producer releases application resources before returning.
- `Failed { reason }`: discard output and receive exactly one `Cancelled` cleanup
  callback with a zero-capacity writer. Do not release the same handle both before
  returning Failed and in that cleanup callback.

`Wake.Ready` requests another bounded scheduler turn. `Wake.After { delay_ms }`
uses an absolute deadline calculated when the producer returns the step; draining a
chunk does not restart the timer. Negative delays and deadline overflow fail with
`InvalidStep`. `Wake.Input` accepts only Input, InputEnd, or InputFailed events;
input views are borrowed for that invocation. HTTP request input is available through `stream_input`; see [streamed HTTP](streamed_http.md).
A zero-delay timer does not permit multiple callbacks within one scheduler call.
When no output is pending, waiting uses `idle_timeout_ms`. Once output becomes
writable, a fresh `write_timeout_ms` budget starts; successful wire progress extends
that write budget. Polling uses the nearest timer or applicable deadline.

## Commitment and terminal cleanup

`commit_requested` signals that output or normal completion needs transport progress.
The owner calls `stream_commit` immediately before offering the first header bytes.
That conservative boundary remains committed even if the first write would block.
An owner may also explicitly commit before a waiting producer emits bytes.

Before commitment, a producer failure sets `render_error`: discard staged response
bytes, then render one ordinary error response. After commitment it sets
`close_required`: close/cancel the transfer without a second response or a successful
chunk terminator. Explicit cancellation never renders an error response.

Normal Done, failure, and cancellation are terminal. Repeated cancellation cannot
repeat producer cleanup. Cancellation discards pending lengths; stale acknowledgements
cannot resume production. A resource-owning producer must handle Cancelled even when
no Ready step has run, including HEAD, bodyless responses, and handler/staging failure.

Every delayed operation carries the exact owner, slot, connection generation, and
request generation. Reusing a connection slot requires terminating the old producer
first and assigning a new key. Stale callbacks and acknowledgements are inert.
Callbacks remain short and synchronous: cancellation cannot safely interrupt a native
call which never returns, as described by the existing execution/shutdown contract.

## Verification

`tests/stream_test.goose` exercises retained bytes, bounded capacity, short and zero
acknowledgements, timer/input eligibility, overflow, commitment, terminal cleanup and
stale generations. `tests/stream_server_test.goose` exercises the production socket
path. `tests/stream_backpressure_test.goose` fills a real socket, observes production
pause while another route remains responsive, then drains and verifies resumption.
Existing continuation/resource fixtures remain regression coverage. Compiler
negative fixtures reject escaped handler-local state and retained input views.

E7.S1 verification on macOS: producer, socket, slow-reader and controlled-clock suites
pass debug and optimized builds. Existing lifecycle, buffered response and runtime
socket regressions pass. New and existing negative state/input fixtures reject the
intended ownership violations in both modes. The runnable reference was served through
the public six-argument overload and delivered five timed chunks plus the terminator.
