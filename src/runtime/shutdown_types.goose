// Flat owning shutdown state can outlive the supervisor's stack; it contains no borrowed Goose views.
namespace silly;

import.lifecycle_types;

enum DrainStatus {
    None,
    Complete,
    Incomplete,
    Failed,
}

struct RuntimeWorker {
    thread: i64 = -1,
    monitor: i64 = -1,
    reader: silly_transport::Descriptor = silly_transport::Descriptor {
    },
    writer: silly_transport::Descriptor = silly_transport::Descriptor {
    },
    ready: bool = false,
    exited: bool = false,
    terminal_reported: bool = false,
    aborted: bool = false,
}

struct RuntimeExit {
    thread: i64,
    lane: bool,
    index: i64,
    ok: bool,
}

struct ShutdownHandle {
    active: bool = false,
    epoch: i64 = 0,
    ticket: i64 = 0,
    workers: RuntimeWorker[4] = [RuntimeWorker {
        }; 4],
    lanes: RuntimeWorker[4] = [RuntimeWorker {
        }; 4],
    worker_count: i64 = 0,
    lane_count: i64 = 0,
    accept_capacity: i64 = 0,
    task_capacity: i64 = 0,
    reply_capacity: i64 = 0,
    reports_reader: silly_transport::Descriptor = silly_transport::Descriptor {
    },
    reports_writer: silly_transport::Descriptor = silly_transport::Descriptor {
    },
    unrecovered_owners: u8 = 0,
    prior_ok: bool = true,
    prior_error: ServerError = ServerError.None,
    prior_system_error: i32 = 0,
    prior_route_issue: RouteIssue = RouteIssue {
    },
    prior_hook_failure: HookResult = HookResult.Ok,
}
