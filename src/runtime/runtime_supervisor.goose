// Bounded round-robin acceptance and worker health monitoring; no connection is serviced here.
namespace silly;

import std;

import.executor_types;
import.runtime;
import.runtime_executor;
import.runtime_mailbox;
import.runtime_monitor;
import.shutdown_types;
import.signals;
import.work_message;
import.worker_message;
import.worker_options;

fn runtime_supervise(options: RuntimeOptions, listeners: silly_transport::Descriptor[:],
    wake: silly_transport::Descriptor, handle: ShutdownHandle&) -> ServerResult {
    var fds: i32[6] = [-1; 6];
    var interests: i32[6] = [0; 6];
    var events: i32[6] = [0; 6];
    for index in listeners.len {
        fds[index] = listeners[index].fd;
    }
    fds[4] = wake.fd;
    fds[5] = handle.reports_reader.fd;
    interests[4] = silly_transport::READ;
    interests[5] = silly_transport::READ;
    var cursor = RuntimeAcceptCursor {
    };
    while true {
        silly_transport::drain_wake(handle.reports_reader);
        let health = runtime_check_reports(handle.workers[..handle.worker_count], handle.lanes[..handle.lane_count]);
        if health.stopped {
            return health.result;
        }
        if health.updated {
            continue;
        }
        if shutdown_signal_requested(options.signal_token) {
            return ServerResult {
                ok: true,
                ..
            };
        }
        let started = runtime_owners_ready(handle.workers[..handle.worker_count])
            && runtime_owners_ready(handle.lanes[..handle.lane_count]);
        for index in listeners.len {
            interests[index] = if started {
                silly_transport::READ
            } else {
                0
            };
        }
        let timeout = if options.signal_token > 0 {
            min(100, options.worker.poll_timeout_ms)
        } else {
            options.worker.poll_timeout_ms
        };
        let ready = silly_transport::poll(fds, interests, events, timeout);
        if ready.status == silly_transport::IoStatus.Interrupted {
            continue;
        }
        if ready.status != silly_transport::IoStatus.Ready {
            return runtime_io_failure(ServerError.Poll, ready);
        }
        if events[4] != 0 {
            return ServerResult {
                ok: true,
                ..
            };
        }
        let admitted = runtime_accept_ready(options, listeners, handle.workers[..handle.worker_count], cursor, events);
        if !admitted.ok {
            return admitted;
        }
    }
    return ServerResult {
        ok: true,
        ..
    };
}

fn runtime_accept(options: RuntimeOptions, listener: silly_transport::Descriptor,
    workers: RuntimeWorker[:], next_owner: i64&, listener_id: i64 = 0) -> ServerResult {
    for attempt in 1 {
        var accepted = silly_transport::accept(listener);
        if accepted.status == silly_transport::IoStatus.WouldBlock
            || accepted.status == silly_transport::IoStatus.Interrupted {
            break;
        }
        if accepted.status != silly_transport::IoStatus.Ready {
            return ServerResult {
                ok: false,
                error: ServerError.Accept,
                system_error: accepted.error,
                ..
            };
        }
        for candidate in workers.len {
            let owner = next_owner;
            next_owner = (next_owner + 1) % workers.len;
            let transferred = route_accept(owner, workers[owner].writer, accepted.descriptor, listener_id);
            if transferred == PublishResult.Full {
                continue;
            }
            // Enqueued descriptors always belong to the worker, including failed notifications.
            // A timed worker poll observes interrupted notifications without republishing.
            if transferred == PublishResult.QueuedOwnerGone {
                return ServerResult {
                    ok: false,
                    error: ServerError.Wake,
                    message: "io owner disappeared",
                    ..
                };
            }
            break;
        }
        // Every queue full: close the still-owned socket; there is no unbounded overflow list.
        silly_transport::close(accepted.descriptor);
    }
    return ServerResult {
        ok: true,
        ..
    };
}

fn runtime_io_failure(error: ServerError, result: silly_transport::IoResult) -> ServerResult {
    return ServerResult {
        ok: false,
        error: error,
        system_error: result.error,
        ..
    };
}

fn runtime_owners_ready(owners: RuntimeWorker[:]) -> bool {
    for owner in owners {
        if !owner.ready {
            return false;
        }
    }
    return true;
}

struct RuntimeHealth {
    updated: bool = false,
    stopped: bool = false,
    result: ServerResult = ServerResult {
        ok: true,
        ..
    },
}

fn runtime_report_health(workers: RuntimeWorker[:], lanes: RuntimeWorker[:]) -> RuntimeHealth {
    let report, present = qpoll<WorkerReport>();
    if present {
        if !report.ready {
            if report.owner >= 0 && report.owner < workers.len {
                workers[report.owner].terminal_reported = true;
            }
            return RuntimeHealth {
                stopped: true,
                result: unexpected_owner_result(worker_result(report)),
                ..
            };
        }
        if report.owner < 0 || report.owner >= workers.len {
            return invalid_runtime_report();
        }
        workers[report.owner].ready = true;
        return RuntimeHealth {
            updated: true,
            ..
        };
    }
    let lane_report, lane_present = qpoll<ExecutorReport>();
    if lane_present {
        if !lane_report.ready {
            if lane_report.lane >= 0 && lane_report.lane < lanes.len {
                lanes[lane_report.lane].terminal_reported = true;
            }
            return RuntimeHealth {
                stopped: true,
                result: unexpected_owner_result(executor_result(lane_report)),
                ..
            };
        }
        if lane_report.lane < 0 || lane_report.lane >= lanes.len {
            return invalid_runtime_report();
        }
        lanes[lane_report.lane].ready = true;
        return RuntimeHealth {
            updated: true,
            ..
        };
    }
    return RuntimeHealth {
    };
}

fn runtime_check_reports(workers: RuntimeWorker[:], lanes: RuntimeWorker[:]) -> RuntimeHealth {
    let health = runtime_report_health(workers, lanes);
    if health.updated || health.stopped {
        return health;
    }
    let event, exited = qpoll<RuntimeExit>();
    if !exited || !record_runtime_exit(event, workers, lanes) {
        return RuntimeHealth {
        };
    }
    // A terminal report may have arrived between the first report poll and this exit poll.
    // Exit is published only after join, so all preceding owner reports are now visible.
    for attempt in 16 {
        let final = runtime_report_health(workers, lanes);
        if final.stopped {
            return final;
        }
        if !final.updated {
            break;
        }
    }
    if event.lane {
        lanes[event.index].aborted = !event.ok || !lanes[event.index].terminal_reported;
    } else {
        workers[event.index].aborted = !event.ok || !workers[event.index].terminal_reported;
    }
    return RuntimeHealth {
        stopped: true,
        result: ServerResult {
            ok: false,
            error: ServerError.WorkerAborted,
            ..
        },
        ..
    };
}

fn invalid_runtime_report() -> RuntimeHealth {
    return RuntimeHealth {
        stopped: true,
        result: ServerResult {
            ok: false,
            error: ServerError.InvalidOptions,
            ..
        },
        ..
    };
}

fn unexpected_owner_result(result: ServerResult) -> ServerResult {
    if !result.ok {
        return result;
    }
    return ServerResult {
        ok: false,
        error: ServerError.WorkerExited,
        message: "owner stopped before shutdown",
        ..
    };
}

struct RuntimeAcceptCursor {
    owner: i64 = 0,
    listener: i64 = 0,
}

fn runtime_accept_ready(options: RuntimeOptions, listeners: silly_transport::Descriptor[:],
    workers: RuntimeWorker[:], cursor: RuntimeAcceptCursor&, events: i32[:]) -> ServerResult {
    for index in listeners.len {
        if (events[index] & (silly_transport::CLOSED | silly_transport::ERROR)) != 0 {
            return ServerResult {
                ok: false,
                error: ServerError.Listen,
                ..
            };
        }
    }
    for attempt in options.worker.accepts_per_turn {
        let index = cursor.listener;
        cursor.listener = (cursor.listener + 1) % listeners.len;
        if (events[index] & silly_transport::READ) != 0 {
            let admitted = runtime_accept(options, listeners[index], workers, cursor.owner, index);
            if !admitted.ok {
                return admitted;
            }
        }
    }
    return ServerResult {
        ok: true,
        ..
    };
}
