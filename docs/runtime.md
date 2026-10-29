# Bounded I/O workers

E6.S1 adds `run_runtime(options, listener, wake, seed, worker)` alongside the existing
single-owner `serve` APIs. It consumes the listener and shutdown wake reader on every
return path. The application retains the wake writer and can notify it to stop the
runtime. Existing `serve` calls continue to use one owner.

Goose requires a concrete top-level `thread_fn`: thread entrypoints cannot be generic
or nested. The application supplies a small bridge, as in `tests/runtime/runtime_server_test.goose`:

```goose
thread_fn worker(start: silly::WorkerStart, seed: i64) {
    silly::run_runtime_worker<Route>(start, seed, initialize, define, handle, lifecycle);
}
```

The callback shapes are `initialize(seed, owner: silly::Owner) -> App`,
`define(router: silly::Router<Route>&, app: App&)`,
`handle(ctx: silly::Context<App, silly::NoStream>&, route: Route)`, and
`lifecycle(app: App&, event: silly::Lifecycle<Route>) -> silly::HookResult`.
`run_runtime_worker_with_errors` additionally takes the existing static error renderer.
The bridge must invoke its worker adapter exactly once and return when it returns.

`seed` and `WorkerStart` are copied flat values. A seed cannot contain an app reference
or borrowed route plan. Initialization creates a separate app inside each worker;
route definition runs against that app and worker-owned route storage. The prepared
plan is immutable for that worker's lifetime. Define routes deterministically when all
workers should expose the same inventory. Lifecycle Start/Stop carry the worker's owner
ID, from zero through `workers - 1`. Every initialized app receives Stop on ordinary
return paths. Invalid routes cause Stop without Start, so resources acquired by the
initializer are still released; the result preserves the route error and any Stop
hook failure. Native resources created during initialization must be released by Stop.
Initializer/callback aborts remain outside this cooperative cleanup contract.

## Admission and memory caps

`RuntimeOptions` defaults to one worker, an admission queue of 16 per worker, a global
connection reservation of 64, and a global slab budget of 512 MiB. `worker` contains
flat `WorkerOptions`, including per-worker connection, buffer and scheduling limits.
Supported worker counts are 1–4. All four static mailbox tags are reserved by a
process-wide runtime lease; a concurrent second runtime is refused. After shutdown,
the lease is released and a later runtime may reuse the drained mailboxes.

Validation reserves this conservative maximum of application-owned connection sockets:

```
workers * (worker.connections_max + accept_queue_max + 1) + 1
```

Each worker gets its live-slot capacity, its full admission queue, and a temporary
message dequeued before adoption/refusal. The supervisor gets one temporarily accepted
socket. This reservation must fit `connections_max`; listener/control sockets and the
kernel's pending listen backlog are separate. Checks divide before multiplying to
avoid overflow. The default per-worker 16 connections and 8 MiB request/response limits
consume slightly over 256 MiB of slabs; additional workers may require smaller limits
or a larger global budget.

`buffer_bytes_max` bounds the sum of allocated input-head, response-head, response-body,
request-body and staging slabs across workers. Worker slab budgets apply independently.
E6.S2 additionally reserves fixed executor payloads when lanes are enabled; see
[blocking executors](executors.md). Fixed metadata, route storage and thread stacks
remain outside this byte counter; route and queue limits bound those owners separately.

The supervisor accepts in bounded turns and distributes to addressed queues. Successful
enqueue transfers the descriptor; refusal retains ownership until the supervisor closes
it. A worker unable to adopt a dequeued descriptor closes it. Saturation therefore closes
excess accepted connections; it does not promise an HTTP overload response. Exactly one
owner may read, write or close each accepted socket. Admission mailboxes are never shared
competing-reader queues.

## Scheduling and shutdown

Each worker has private connection slots and nonmoving buffer slabs. Read/write operations
are limited by `work_bytes_per_turn`; `dispatches_per_turn` bounds connection service
operations per turn, with a rotating cursor. `accepts_per_turn` bounds admission draining.
Polling uses descriptor readiness and the nearest phase or inactivity deadline. Staged input or exhausted
service/mailbox budgets trigger another bounded turn. Would-block writes wait for readiness;
there is one bounded buffered response per connection and sequential keep-alive dispatch.

Every queue has a positive `qlimit` before producers start. Enqueue precedes notification;
readers drain wake bytes before mailboxes. Refused puts have explicit ownership/error paths.
The shared report queue reserves two reports per configured owner: successful readiness
and final termination. Failed startup may report only termination. A separate report wake
socket wakes the supervisor; its writer stays valid until every worker joins. The runtime
opens admission only after all workers report readiness. Worker failures stop admission
and cause shutdown of the other workers, preserving a reported error.

Shutdown closes admission, drains existing responses, then cancels eligible connections at
`RuntimeOptions.shutdown_timeout_ms`. Owners run Stop in their own domains. A blocked
native call returns an explicit incomplete drain with an owned `ShutdownHandle`; callers
retain it and call `resume_shutdown` to finish cleanup. Contained worker aborts poison
the runtime rather than pretending foreign resources were reclaimed. See
[shutdown and deadlines](shutdown.md) for ownership, signals and failure contracts.

`run_runtime_listeners` and `run_runtime_listeners_with_executor` consume up to four
listeners under one supervisor and shared executor registration. `Request.listener_id`
identifies their input index, allowing API and Portal routing without duplicating native
state. The optional signal adapter is installed and removed explicitly by the caller.

## Verification

`runtime_options_test` checks cap boundaries and overflow rejection. `runtime_queue_test`
checks ownership transfer, mailbox/slot saturation and resource reclamation.
`runtime_scheduler_test` checks deterministic turn rotation and deadline selection.
`runtime_server_test` exercises two/four real workers, isolated app state, persistence,
stalled readers, singleton refusal, failed Start and repeated restart.
`runtime_startup_test` verifies initializer-owned descriptors are released exactly once
when route preparation fails, including a failed Stop hook after resource release.

E6.S2 adds [bounded blocking executors](executors.md) through `run_runtime_with_executor`,
with a second concrete thread bridge, copied request/response snapshots and addressed
completion queues. `run_runtime` rejects executor-enabled options without that bridge.
