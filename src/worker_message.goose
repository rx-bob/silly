// Addressed admission transfers descriptor ownership only after a successful enqueue.
namespace silly;

import std;

import.completion_router;
import.executor_types;
import.lifecycle_types;
import.route_types;
import.server_options;
import.transport;
import.work_message;
import.worker_options;

// Copied launch data: wake transfers to this owner; report_wake is borrowed until all owners join.
struct WorkerStart {
    options: WorkerOptions,
    owner: i64,
    wake: i32,
    report_wake: i32,
    executor: ExecutorOptions = ExecutorOptions {
    },
    lane_writers: i32[4] = [-1; 4],
}

struct IoOwner0 {
}
struct IoOwner1 {
}
struct IoOwner2 {
}
struct IoOwner3 {
}

struct AcceptMessage<Tag> {
    fd: i32,
}

struct WorkerStop<Tag> {
    stop: bool = true,
}

// One supervisor consumes these reports; each worker publishes readiness and termination once.
struct WorkerReport {
    owner: i64,
    ready: bool = false,
    ok: bool,
    error: ServerError = ServerError.None,
    system_error: i32 = 0,
    route_issue: RouteIssue = RouteIssue {
    },
    hook_failure: HookResult = HookResult.Ok,
}

struct RuntimeLease {
    held: bool = true,
}

fn publish_accept<Tag>(wake: silly_transport::Descriptor, socket: silly_transport::Descriptor&) -> PublishResult {
    if !qput(AcceptMessage<Tag> {
            fd: socket.fd
        }) {
        return PublishResult.Full;
    }
    socket.fd = -1;
    return retry_completion_wake(wake);
}

// Only the supervisor after joining the sole reader may reclaim the remaining resource messages.
fn discard_accepts<Tag>(capacity: i64) -> i64 {
    var count = 0;
    for index in max(0, capacity) {
        let accepted, present = qpoll<AcceptMessage<Tag>>();
        if !present {
            break;
        }
        var socket = silly_transport::Descriptor {
            fd: accepted.fd
        };
        silly_transport::close(socket);
        count += 1;
    }
    return count;
}

fn worker_report(owner: i64, result: ServerResult) -> WorkerReport {
    return WorkerReport {
        owner: owner,
        ok: result.ok,
        error: result.error,
        system_error: result.system_error,
        route_issue: result.route_issue,
        hook_failure: result.hook_failure,
        ..
    };
}

fn worker_result(report: WorkerReport) -> ServerResult {
    return ServerResult {
        ok: report.ok,
        error: report.error,
        message: if report.ok {
            ""
        } else {
            "io worker failed"
        },
        system_error: report.system_error,
        route_issue: report.route_issue,
        hook_failure: report.hook_failure,
    };
}

// Two reserved records per owner make refusal an internal protocol violation, never overload.
fn publish_worker_report(wake: i32, report: WorkerReport) {
    assert(qput(report));
    // Enqueue before notify. Interrupted notification falls back to the bounded supervisor poll.
    silly_transport::notify(silly_transport::Descriptor {
            fd: wake
        });
}
