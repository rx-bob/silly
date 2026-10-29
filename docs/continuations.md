# E1.S4 ownership and callback gate

The executable gate now proves the application callback model, independent retained
producer state, reusable storage, stale-completion rejection, targeted owner mailboxes
and bounded shutdown outcomes. This freezes the **language and ownership contract**.
It does not claim production routing, SSE, timer scheduling or the target `serve`
overloads already exist. E3/E6/E7 implement those behaviors using these primitives.

## Supported callback surface

`tests/support/api_contract_test.goose` calls proof-local `serve<R>`, `serve<R,A>` and
`serve<R,A,S>` with exactly three, five and six arguments, matching the target references.
The adapters use real `Context<A,S>`, request/response owners, `StreamStart<S>`,
`start_stream`, `StreamEvent`, `StreamStep`, `Wake` and `ChunkWriter`. Router and lifecycle
fixture declarations are labeled proof-local; they do not replace production modules.

Named startup/handler/step/lifecycle callbacks are compiler arguments, never stored
function values. `A` is copied into its execution owner. The handler receives borrowed
context, creates an owned inline `S`, hands it off, clears its original local, then
returns. Later steps observe the retained copy and receive short-lived input views.
All StreamEvent and StreamStep variants and lifecycle callback shapes compile and run.

`Context.stream_start` is an optional reference to a driver-owned `StreamStart<S>`.
`start_stream(ctx, status, state)` requires that sink and a fresh response. It checks
fixed-size `S` using `default<S>()`, copies state into the sink, and selects the Stream
response mode. Missing sink and duplicate selection return typed errors without
overwriting an existing response. An explicitly initialized sink cannot bypass the
fixed-size check. Fixed-size state containing a handler-local view is rejected by the
compiler's destination-lifetime check. Larger owned resources require bounded pool IDs.

The buffered HTTP writer and memory transport explicitly refuse Stream mode. E1.S3's
buffered server therefore cannot silently deliver a selected stream as an empty response.
E7's `events`/`stream_input` helpers will use this handoff and provide HTTP semantics.

One spelling changed based on an actual compiler rejection: **use
`silly::append(out, bytes)` for custom writers**. Goose resolves `out.append(bytes)` as
the built-in array operation and rejects ChunkWriter. The request-stream and HTML
reference sketches, relevant inline epic examples and affected story notes in the
supplied plan are updated together. Ordinary array `.append` remains unchanged.

## Continuation ownership

`Continuation<S>` is a fixed reusable-slot record containing owned producer state,
a `TransferKey`, phase, wake data, produced/acknowledged offsets and a bounded 4096-byte
owned chunk. It contains no callback, Context, or retained StreamEvent input view.
`resume(slot, key, event, step)` invokes the static step once. `ChunkWriter` borrows the
slot's chunk only for that invocation. Appending copies into it with a checked cap.
Growing the descriptor pool leaves existing transfers independent and intact.

| State/outcome | Owner rule |
| --- | --- |
| Ready / Waiting | Owner checks readiness, requested input or timer eligibility, then invokes a short step |
| Chunk | Positive bounded chunk becomes Pending; preserve bytes and offsets until acknowledged |
| Pending | A further resume is refused; partial acknowledgement advances only the acknowledged offset |
| Full acknowledgement | Changes to Waiting; owner applies the stored wake condition before the next step |
| Wait | Must produce zero bytes and a valid wake; yields without output |
| Done | Must produce zero bytes; producer releases its application resources before returning Done |
| Failed / invalid step | Mark Failed once, then invoke Cancelled once with a zero-capacity writer for producer cleanup |
| Explicit Cancelled | Mark Cancelled first, invoke producer cleanup once with zero capacity; ignore its returned outcome |
| Terminal | Future resume, acknowledge and cancel cannot mutate state or repeat cleanup |

Failure cleanup uses the Cancelled event; producers must not close the same resource
both before returning Failed and again in Cancelled. Normal Done cleanup occurs in the
producer's final step. The owner releases its own chunk/pool resources only after this
terminal boundary. No retained callback frame or automatic C resource unwinding is
assumed. A noncooperative/aborting cleanup callback retains the explicit E6 limitations.
`continuation_resource_test.goose` verifies actual descriptor closure exactly once for
normal completion, explicit cancellation, producer failure and invalid producer output.

`Wake.After` carries a finite nonnegative relative delay; `Wake.Input` requests the
next bounded input event; `Wake.Ready` requests readiness. This module validates step
shape, not OS readiness or deadlines. E7's owner must check timer-addition overflow and
eligibility before calling resume. `flush` requests transport progress, not synchronous
delivery. Cancellation may interrupt Pending output; subsequent acknowledgements are inert.

## Reuse, identity and copy points

`TransferKey { owner, slot, connection_generation, request_generation }` is flat data.
Every resume, acknowledgement and cancellation compares **all four** fields before
touching producer state or offsets. Generations are nonzero and owner/slot nonnegative.
The driver maintains increasing generations; exhausted counters retire rather than wrap.
Raw `reusable` allocation does not invent identities or enforce terminal state: the owner
must finish/cancel the old slot before freeing it and assign a fresh key on reuse.

The tests recycle the same slot for a new connection, then for a new request on that
connection. Old completions and wrong-owner messages cannot alter the new output or
cleanup state. Each new slot resets its chunk, offsets and terminal marker. Future E2
persistence and E6 executors must supply request generations; E1.S3 remains close-only.

`continuation_pool_test.goose` separately proves `reusable[]` byte allocation, forced
relocation on growth, free and zero-initialized reuse. A retained descriptor stores only
start/length/generation. A temporary slice is recomputed for each operation and the
descriptor is updated after realloc. No stale slice survives a resumption boundary.
Compiler lifetime checks alone cannot detect a logically recycled slot; key checks are
required even though its address is still memory-safe.

Copy costs are explicit: fixed `S` is copied at handoff, step input is copied only when
appended to an output chunk, queue payloads are copied flat values, and relocatable byte
runs may copy on growth. `terminal` borrows the record rather than copying its chunk.
No zero-copy or throughput claim is made.

## Targeted mailboxes and shutdown

Goose queues are keyed by **element type**, not by thread. `WorkMessage` carries a flat
key, operation and at most 256 owned bytes. `WorkCompletion<OwnerTag>` adds a static
owner type to completion identity. Distinct owner tags produce distinct queues even
though the tag occupies no field. The dispatcher chooses a known tag from the numeric
owner ID. E6 must instantiate a bounded static owner-tag set and reject configurations
outside it; a shared completion queue with competing readers is not permitted.

Exactly one live reader consumes each owner mailbox. `qlimit` is installed before any
producer starts. Payloads contain no borrowed addresses or native handles. Full work or
completion queues return refusal immediately; callers retain/retry their bounded work
or apply admission/cancellation policy. There is no dequeue/requeue routing loop.

`publish_completion` first checks the numeric owner binding, enqueues one owned copy,
then notifies that owner's nonblocking wake socket:

| Result | Ownership and next action |
| --- | --- |
| WrongOwner / Full | Nothing enqueued; caller still owns its completion |
| Queued | One mailbox copy exists; wake succeeded or an already-full wake socket coalesced notification |
| QueuedNeedsWake | Enqueue succeeded but notification was interrupted; retry **only** wake with a bounded budget, never republish |
| QueuedOwnerGone | Enqueue succeeded but wake failed/peer closed; supervisor must reclaim after producer quiescence |

The consumer drains wake bytes **before** draining its mailbox. Reversing that order can
erase a concurrent notification. If its bounded mailbox-drain budget is exhausted, it
reschedules without blocking. Each turn also checks the mailbox before sleeping; an
interrupted wake retry cannot become unbounded spinning. Native wake calls retain no
Goose pointers, and an accepted completion remains queued even when wake fails.

Goose has no queue-close primitive. Shutdown closes admission, requests cancellation,
waits for all admitted producers to finish, joins the old reader, and only then allows
the supervisor to become the sole mailbox reader. A reader may exit before a producer;
the tested late publish yields QueuedOwnerGone. Do not close or reuse a producer's wake
writer descriptor while it can still notify. `discard_completions<Owner>(capacity)`
performs bounded post-join reclamation. Current messages contain owned bytes only, so
discard needs no foreign-resource cleanup. Future resource-bearing work requires an
explicit owner-side release protocol, not silently dropping a numeric descriptor.

The real-thread queue fixture services the second owner before the first and verifies
that neither steals messages. It also verifies queue saturation, caller-buffer mutation
after copy, a deterministically ordered shutdown race, and full-wake coalescing without
duplicate enqueue. Control queues have finite capacities and timed waits; no sleep race
is used to decide test order.

## Verification and boundaries

Five positive fixtures: `continuation_test`, `continuation_pool_test`,
`continuation_resource_test`, `api_contract_test`, and `queue_routing_test`.
[Seven negative fixtures](../tests/lifetimes/README.md) verify request/output lifetime,
local escape, const request access, stream-state escape, resizable state and nonflat
queue rejection. Expected diagnostic text is checked, not merely a nonzero exit.

Release/debug builds and runs use matching Goose runtime `4d3da949e563` on macOS arm64
with Apple clang 17 and Ubuntu 24.04 x64 (Docker Desktop emulation) with GCC 13.3.
Existing context, HTTP head and real-server fixtures remain regression gates. No
production queue executor, timer scheduler, SSE formatting or new native shim is added.
The standalone `reference/dispatch_proof.goose` remains the narrow original guard proof;
the new fixtures provide its missing ownership and callback evidence.

Final E1.S4 result: all five positive fixtures pass both modes on both platforms;
all seven intended compiler rejections match their expected diagnostics in both modes.
Affected context/HTTP/server regressions also pass both modes on macOS. Formatter and
whitespace checks pass (retaining E1.S3's narrow writable-FFI G015 configuration).
Stack/BCE inspection reports five data-stack regions for the continuation fixture;
the checked chunk-copy loop retains four bounds checks across specializations, so no
`checkfree` claim is made. No copy-on-return warning occurred. Linux artifacts live at
`/tmp/silly-s4-linux` for this workspace session.

Next: **E2.S1 — Parse request heads incrementally with strict framing validation**.
