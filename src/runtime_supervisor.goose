// Bounded round-robin acceptance and worker health monitoring; no connection is serviced here.
namespace silly;

import std;

import.runtime;
import.runtime_mailbox;
import.server_options;
import.transport;
import.work_message;
import.worker_message;
import.worker_options;

fn runtime_supervise(options: RuntimeOptions, listener: silly_transport::Descriptor,
    wake: silly_transport::Descriptor, reports: silly_transport::Descriptor,
    workers: RuntimeWorker[:]) -> ServerResult {
    let fds: i32[3] = [listener.fd, wake.fd, reports.fd];
    var interests: i32[3] = [0, silly_transport::READ, silly_transport::READ];
    var events: i32[3] = [0, 0, 0];
    var next_owner: i64 = 0;
    while true {
        // Drain wake before the report mailbox, matching accepted-socket notification ordering.
        silly_transport::drain_wake(reports);
        let report, present = qpoll<WorkerReport>();
        if present {
            if !report.ready {
                return worker_result(report);
            }
            if report.owner < 0 || report.owner >= workers.len {
                return ServerResult {
                    ok: false,
                    error: ServerError.InvalidOptions,
                    ..
                };
            }
            workers[report.owner].ready = true;
            // Finite readiness records (one per worker); check again before sleeping.
            continue;
        }
        var started = true;
        for worker in workers {
            if !worker.ready {
                started = false;
            }
        }
        interests[0] = if started {
            silly_transport::READ
        } else {
            0
        };
        let ready = silly_transport::poll(fds, interests, events, options.worker.poll_timeout_ms);
        if ready.status == silly_transport::IoStatus.Interrupted {
            continue;
        }
        if ready.status != silly_transport::IoStatus.Ready {
            return runtime_io_failure(ServerError.Poll, ready);
        }
        if events[1] != 0 {
            return ServerResult {
                ok: true,
                ..
            };
        }
        if (events[0] & (silly_transport::CLOSED | silly_transport::ERROR)) != 0 {
            return ServerResult {
                ok: false,
                error: ServerError.Listen,
                ..
            };
        }
        if (events[0] & silly_transport::READ) != 0 {
            let admitted = runtime_accept(options, listener, workers, next_owner);
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

fn runtime_accept(options: RuntimeOptions, listener: silly_transport::Descriptor,
    workers: RuntimeWorker[:], next_owner: i64&) -> ServerResult {
    for attempt in options.worker.accepts_per_turn {
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
            let transferred = route_accept(owner, workers[owner].writer, accepted.descriptor);
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
