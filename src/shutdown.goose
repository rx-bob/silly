// Resumable drain ownership. A deadline never terminates application/native threads.
namespace silly;

import std;

import.executor;
import.runtime_control;
import.runtime_executor;
import.runtime_mailbox;
import.runtime_monitor;
import.server_options;
import.shutdown_types;
import.transport;
import.worker_message;

fn resume_shutdown(handle: ShutdownHandle&, timeout_ms: i64) -> ServerResult {
    if !handle.active || timeout_ms < 0 {
        return invalid_shutdown_result(ServerError.InvalidShutdownHandle);
    }
    if !runtime_control_claim_ticket(handle.epoch, handle.ticket) {
        let stale = runtime_control_ticket(handle.epoch) != handle.ticket;
        if stale {
            handle.active = false;
        }
        return invalid_shutdown_result(if stale {
                ServerError.InvalidShutdownHandle
            } else {
                ServerError.ShutdownBusy
            });
    }
    var owned = handle;
    handle.active = false;
    let clock = silly_transport::monotonic_ms();
    if clock.status != silly_transport::IoStatus.Ready || timeout_ms > 0x7fffffffffffffff - clock.count {
        owned.prior_ok = false;
        owned.prior_error = ServerError.Clock;
        return retain_shutdown(owned);
    }
    let deadline = clock.count + timeout_ms;
    while true {
        collect_shutdown_reports(owned);
        if shutdown_owners_exited(owned) {
            return complete_shutdown(owned);
        }
        let now = silly_transport::monotonic_ms();
        if now.status != silly_transport::IoStatus.Ready || now.count >= deadline {
            return retain_shutdown(owned);
        }
        let fds: i32[1] = [owned.reports_reader.fd];
        let interests: i32[1] = [silly_transport::READ];
        var events: i32[1] = [0];
        let ready = silly_transport::poll(fds, interests, events, min(100, deadline - now.count)as i32);
        if ready.status != silly_transport::IoStatus.Ready && ready.status != silly_transport::IoStatus.Interrupted {
            owned.prior_ok = false;
            owned.prior_error = ServerError.Poll;
            owned.prior_system_error = ready.error;
            return retain_shutdown(owned);
        }
    }
    return retain_shutdown(owned);
}

fn begin_runtime_drain(handle: ShutdownHandle&) {
    runtime_control_close(handle.epoch);
    for lane in handle.lane_count {
        route_executor_stop(lane, handle.lanes[lane].writer);
    }
    notify_shutdown_owners(handle);
}

fn notify_shutdown_owners(handle: ShutdownHandle&) {
    for index in handle.worker_count {
        silly_transport::notify(handle.workers[index].writer);
    }
    for index in handle.lane_count {
        silly_transport::notify(handle.lanes[index].writer);
    }
}

fn retain_shutdown(handle: ShutdownHandle&) -> ServerResult {
    runtime_control_cancel(handle.epoch);
    notify_shutdown_owners(handle);
    handle.ticket = runtime_control_release(handle.epoch);
    assert(handle.ticket >= 0);
    return ServerResult {
        ok: false,
        error: ServerError.IncompleteDrain,
        message: "shutdown incomplete; retain pending handle and resume after native work completes",
        drain: DrainStatus.Incomplete,
        pending: handle,
        unrecovered_owners: handle.unrecovered_owners,
        ..
    };
}

fn collect_shutdown_reports(handle: ShutdownHandle&) {
    // Drain wake before typed mailboxes; bounded report counts cannot monopolize a turn.
    silly_transport::drain_wake(handle.reports_reader);
    collect_shutdown_owner_reports(handle);
    for index in 8 {
        let event, present = qpoll<RuntimeExit>();
        if !present {
            break;
        }
        record_runtime_exit(event, handle.workers[..handle.worker_count], handle.lanes[..handle.lane_count]);
    }
    // Terminal reports precede exits, but may race the first mailbox pass.
    collect_shutdown_owner_reports(handle);
    mark_aborted_owners(handle);
}

fn collect_shutdown_owner_reports(handle: ShutdownHandle&) {
    for index in 8 {
        let report, present = qpoll<WorkerReport>();
        if !present {
            break;
        }
        if !report.ready && report.owner >= 0 && report.owner < handle.worker_count {
            handle.workers[report.owner].terminal_reported = true;
        }
        if !report.ok {
            remember_shutdown_result(handle, worker_result(report));
        }
    }
    for index in 8 {
        let report, present = qpoll<ExecutorReport>();
        if !present {
            break;
        }
        if !report.ready && report.lane >= 0 && report.lane < handle.lane_count {
            handle.lanes[report.lane].terminal_reported = true;
        }
        if !report.ok {
            remember_shutdown_result(handle, executor_result(report));
        }
    }
}

fn mark_aborted_owners(handle: ShutdownHandle&) {
    for index in handle.worker_count {
        if handle.workers[index].aborted
            || (handle.workers[index].exited && !handle.workers[index].terminal_reported) {
            handle.unrecovered_owners |= (1 << index)as u8;
        }
    }
    for index in handle.lane_count {
        if handle.lanes[index].aborted
            || (handle.lanes[index].exited && !handle.lanes[index].terminal_reported) {
            handle.unrecovered_owners |= (1 << (index + 4))as u8;
        }
    }
    if handle.unrecovered_owners != 0 {
        runtime_control_poison(handle.epoch);
        notify_shutdown_owners(handle);
    }
}

fn shutdown_owners_exited(handle: ShutdownHandle&) -> bool {
    return runtime_owners_exited(handle.workers[..handle.worker_count])
        && runtime_owners_exited(handle.lanes[..handle.lane_count]);
}

fn complete_shutdown(handle: ShutdownHandle&) -> ServerResult {
    join_runtime_monitors(handle.workers[..handle.worker_count]);
    join_runtime_monitors(handle.lanes[..handle.lane_count]);
    reclaim_runtime_mailboxes(handle.accept_capacity);
    reclaim_runtime_executor_mailboxes(ExecutorOptions {
            queue_max: handle.task_capacity,
            outstanding_per_owner: handle.reply_capacity,
            ..
        });
    close_runtime_owners(handle.workers);
    close_runtime_owners(handle.lanes);
    silly_transport::close(handle.reports_reader);
    silly_transport::close(handle.reports_writer);
    let poisoned = handle.unrecovered_owners != 0 || runtime_control_poisoned()
        || runtime_control_submissions(handle.epoch) != 0;
    runtime_control_finish(handle.epoch, poisoned);
    if !poisoned {
        let lease, held = qpoll<RuntimeLease>();
        assert(held);
    }
    handle.active = false;
    return ServerResult {
        ok: handle.prior_ok && !poisoned,
        error: if poisoned {
            ServerError.WorkerAborted
        } else {
            handle.prior_error
        },
        message: if poisoned {
            "worker exited unsafely; foreign resources unrecovered and runtime poisoned"
        } else if !handle.prior_ok {
            "runtime owner failed"
        } else {
            ""
        },
        system_error: handle.prior_system_error,
        route_issue: handle.prior_route_issue,
        hook_failure: handle.prior_hook_failure,
        drain: if poisoned {
            DrainStatus.Failed
        } else {
            DrainStatus.Complete
        },
        unrecovered_owners: handle.unrecovered_owners,
        ..
    };
}

fn remember_shutdown_result(handle: ShutdownHandle&, result: ServerResult) {
    if handle.prior_ok && !result.ok {
        handle.prior_ok = false;
        handle.prior_error = result.error;
        handle.prior_system_error = result.system_error;
        handle.prior_route_issue = result.route_issue;
        handle.prior_hook_failure = result.hook_failure;
    }
}

fn invalid_shutdown_result(error: ServerError) -> ServerResult {
    return ServerResult {
        ok: false,
        error: error,
        message: "invalid, stale or busy shutdown handle",
        ..
    };
}
