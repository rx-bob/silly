# Runtime shutdown and failure ownership

`run_runtime` and `run_runtime_with_executor` consume a listener and a caller-owned
shutdown wake reader. A wake byte/closed peer requests shutdown. The listener-group
forms, `run_runtime_listeners` and `run_runtime_listeners_with_executor`, consume a
mutable descriptor slice of one through four distinct listeners. All share the same
bounded worker/lane pool and ordered route inventory; `Request.listener_id` is the
zero-based input index and survives execution snapshots. This supports coordinated API
and Portal ports without pretending that process-global native state can have two
independent owners. Application dispatch chooses behavior for each listener.

Importing Silly never installs signal handlers or owns `main`. To opt in, call
`install_shutdown_signals()`, check its `ok`, and copy its token into
`RuntimeOptions.signal_token`. SIGINT/SIGTERM only set a lock-free atomic `sig_atomic_t` flag; the
supervisor checks it with a maximum 100 ms signal-poll interval. No application
callback, allocation, mutex, descriptor write or cleanup runs in the signal handler.
The caller retains the adapter and calls `uninstall_shutdown_signals(adapter)` to
restore the previous handlers. Uninstall refuses to overwrite handlers replaced by another
component; the caller must resolve that conflict. One adapter may be installed at a time. Tests execute
signals only in freshly exec'd isolated child processes.

## Drain ordering

`RuntimeOptions.shutdown_timeout_ms` defaults to 5000 and may be zero. Shutdown:

1. Closes the native admission gate and all listeners. Admission checks linearize
   under a small native mutex; operations that already acquired their permit are
   in flight. The gate contains no request pointers or native application state.
2. Wakes I/O owners and stops executor queues. Submission permits keep lanes alive
   until pre-closure publishers finish enqueueing. Queued endpoint jobs are abandoned;
   their callbacks never start. Active synchronous endpoint invocations finish on
   their original lane. No thread termination is attempted.
3. I/O owners close idle/incomplete readers, stop reading new requests and continue
   already-admitted execution replies and buffered writes. Keep-alive reuse stops.
4. Each owner calls Stop after its own work is completed or cancelled. A lane's Stop
   follows its final native invocation; I/O Stop follows its transport cleanup.
   Lane Stop may precede delivery of its copied reply. Cross-owner Stop ordering is
   otherwise unspecified, so I/O lifecycle callbacks must never access lane-owned
   native globals.
5. At the shutdown deadline, eligible I/O connections are cancelled. Running native
   calls and their storage remain owned. Monitors report actual owner exits; cleanup
   closes producer wake writers only after their owners and monitors have joined.

Head/body deadlines are absolute phase budgets (`head_timeout_ms`,
`body_timeout_ms`). Idle timeout follows transport activity. Write timeout follows
write progress (`write_timeout_ms`); execution retains its admission deadline,
including queue delay. All default to 30000 ms, except separately configured executor
settings. Polling uses the nearest applicable monotonic deadline. Completion metadata
carries a typed timeout reason. A long-running producer must use activity/idle semantics
rather than continually refreshing an absolute head/body deadline.

Production HTTP streaming remains E7 work. Current runtime drains buffered output and
executor tasks. Application-owned E1 continuation state is cancelled through its
owner's Stop cleanup using the existing exact-key cancellation contract; this is not a
claim that an HTTP stream scheduler has already been implemented.

## Incomplete drain is an owning result

At a deadline, a nonreturning native call cannot be safely killed. The runtime returns
`ServerError.IncompleteDrain`, `DrainStatus.Incomplete` and an active `result.pending`
`ShutdownHandle`. The handle owns fixed copies of thread/monitor identities, queue
capacities and live wake descriptors; it borrows no supervisor stack or app references.
The original threads and typed queues retain their work and application resources.
The runtime lease stays held, so another runtime is refused with `ShutdownBusy`.

Retain this handle and later call `resume_shutdown(handle, timeout_ms)`. A valid call
consumes that handle. If still incomplete, retain the *new* result's pending handle.
Native epoch/revision checks reject stale copied handles before touching queues or
file descriptors; an exclusive reaper claim rejects concurrent cleanup attempts.
A completed result invalidates ownership and releases the runtime lease. Do not drop
an active handle and claim that resources were released. The embedding application
chooses whether to keep waiting or terminate its process.

Once the first deadline cancels a connection, late native replies are discarded rather
than delivered to that cancelled/reused connection. Completion capacity remains
reserved by outstanding task credits even if its I/O owner has already stopped.

## Unexpected owner exits

Application owners use `thread_spawn_contained`; a separate fixed monitor thread calls
`thread_wait` and reports actual exit even if no lifecycle/report callback ran.
Containment releases Goose storage, **not foreign descriptors or native globals**.
An abort closes admission, coordinates cancellation of surviving owners and reports
`WorkerAborted`, `DrainStatus.Failed` and an `unrecovered_owners` bit mask (I/O bits 0–3,
executor bits 4–7). If other native calls are still running, the result remains an
incomplete owning handle until they finish.

The runtime lease remains poisoned after an unproven owner exit. There is no automatic
respawn or reset API and no claim that Stop ran on the aborted owner. Known supervised
queues/writers are reclaimed after all producers stop; resources lost inside the
aborted owner may remain open. The application needs process termination or separately
proven resource recovery. Native crashes/guard-page failures can still terminate the
process; Goose containment is not a C crash-recovery boundary.

## Verification

`phase_timeout_test` uses controlled monotonic timestamps to distinguish absolute phase
budgets from activity timers. `shutdown_resume_test` exercises active native work,
known queued work, idle/partial readers, stale handles and resumed cleanup.
`shutdown_abort_test` runs in its own executable and verifies unrecovered foreign
descriptors and poisoned restart refusal. `shutdown_listeners_test` covers both grouped
listener entrypoints. `shutdown_report_test` covers early clean owner exits without
false poisoning; `shutdown_submission_test` holds a pre-close permit and publishes only
after the lane receives Stop, proving the task still gets an abandoned reply.
`shutdown_continuation_test` verifies one cancellation and resource
release for an owned producer waiting for activity. `runtime_server_test` also covers
blocked writers and repeated runtime reuse. `signal_adapter_test` uses exec children
for both signals and tests actual runtime shutdown and handler restoration.
