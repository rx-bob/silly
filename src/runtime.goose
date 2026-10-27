// A single supervisor owns admission; up to four independent I/O owners consume addressed queues.
namespace silly;

import std;

import.executor;
import.runtime_executor;
import.runtime_mailbox;
import.runtime_supervisor;
import.server_options;
import.transport;
import.worker_message;
import.worker_options;

struct RuntimeWorker {
    thread: i64 = -1,
    reader: silly_transport::Descriptor = silly_transport::Descriptor {
    },
    writer: silly_transport::Descriptor = silly_transport::Descriptor {
    },
    ready: bool = false,
}

// Consumes listener and wake on every path. W is a concrete application thread_fn;
// C is copied flat startup configuration, never an app reference or a borrowed route plan.
fn run_runtime<C, W>(options: RuntimeOptions, listener: silly_transport::Descriptor,
    wake: silly_transport::Descriptor, seed: C) -> ServerResult {
    fn no_lanes(settings: RuntimeOptions, workers: RuntimeWorker[:], lanes: RuntimeWorker[:],
        report_wake: i32, config: C) {
    }
    return run_runtime_entry(options, listener, wake, seed, false, W, no_lanes);
}

fn run_runtime_entry<C, W, S>(options: RuntimeOptions, listener: silly_transport::Descriptor,
    wake: silly_transport::Descriptor, seed: C, executor: bool) -> ServerResult {
    var incoming = listener;
    var control = wake;
    var result = ServerResult {
        ok: false,
        error: ServerError.InvalidOptions,
        message: "invalid runtime options",
        ..
    };
    if valid_runtime_options(options) && (executor || options.executor.lanes == 0)
        && listener.fd >= 0 && wake.fd >= 0 && listener.fd != wake.fd {
        qlimit<RuntimeLease>(1);
        if qput(RuntimeLease {
            }) {
            result = runtime_owned(options, incoming, control, seed, W, S);
            let lease,
            held = qpoll<RuntimeLease>();
            assert(held);
        } else {
            result.message = "an io runtime is already active";
        }
    }
    silly_transport::close(incoming);
    if control.fd != listener.fd {
        silly_transport::close(control);
    }
    return result;
}

fn runtime_owned<C, W, S>(options: RuntimeOptions, listener: silly_transport::Descriptor,
    wake: silly_transport::Descriptor, seed: C) -> ServerResult {
    initialize_runtime_mailboxes(options.accept_queue_max);
    initialize_executor_mailboxes(options.executor, options.workers);
    var workers: RuntimeWorker[4] = [RuntimeWorker {
        }; 4];
    var lanes: RuntimeWorker[4] = [RuntimeWorker {
        }; 4];
    var reports = silly_transport::wake_pair();
    if reports.status != silly_transport::IoStatus.Ready {
        return runtime_io_failure(ServerError.Wake, silly_transport::IoResult {
                status: reports.status,
                error: reports.error,
                ..
            });
    }
    let opened = open_runtime_owners(workers[..options.workers], lanes[..options.executor.lanes]);
    if !opened.ok {
        silly_transport::close(reports.reader);
        silly_transport::close(reports.writer);
        return opened;
    }
    S(options, workers[..options.workers], lanes[..options.executor.lanes], reports.writer.fd, seed);
    spawn_runtime_workers(options, workers[..options.workers], lanes[..options.executor.lanes],
        reports.writer.fd, seed, W);
    var result = runtime_supervise(options, listener, wake, reports.reader,
        workers[..options.workers], lanes[..options.executor.lanes]);
    stop_runtime_owners(workers[..options.workers], lanes[..options.executor.lanes]);
    // All producers/readers have joined. Only now reclaim resource messages and close wake writers.
    reclaim_runtime_mailboxes(options.accept_queue_max);
    reclaim_runtime_executor_mailboxes(options.executor);
    close_runtime_owners(workers);
    close_runtime_owners(lanes);
    silly_transport::close(reports.reader);
    silly_transport::close(reports.writer);
    collect_runtime_results(result);
    return result;
}

fn spawn_runtime_workers<C, W>(options: RuntimeOptions, workers: RuntimeWorker[:],
    lanes: RuntimeWorker[:], report_wake: i32, seed: C) {
    let writers = runtime_owner_writers(lanes);
    for owner in workers.len {
        workers[owner].thread = thread_spawn(W, WorkerStart {
                options: options.worker,
                owner: owner,
                wake: workers[owner].reader.fd,
                report_wake: report_wake,
                executor: options.executor,
                lane_writers: writers,
            }, seed);
        workers[owner].reader.fd = -1;
    }
}

fn open_runtime_workers(workers: RuntimeWorker[:]) -> ServerResult {
    for owner in workers.len {
        let pair = silly_transport::wake_pair();
        if pair.status != silly_transport::IoStatus.Ready {
            for &worker in workers {
                silly_transport::close(worker.reader);
                silly_transport::close(worker.writer);
            }
            return ServerResult {
                ok: false,
                error: ServerError.Wake,
                message: "worker wake creation failed",
                system_error: pair.error,
                ..
            };
        }
        workers[owner].reader = pair.reader;
        workers[owner].writer = pair.writer;
    }
    return ServerResult {
        ok: true,
        ..
    };
}

// Production bind convenience. External shutdown users pass their listener/control to run_runtime.
fn serve_runtime<C, W>(address: const u8[:], port: i32, options: RuntimeOptions, seed: C) -> ServerResult {
    if !valid_runtime_options(options) || port < 0 || port > 65535 {
        return ServerResult {
            ok: false,
            error: ServerError.InvalidOptions,
            ..
        };
    }
    var listener = silly_transport::listen(address, port, 128);
    if listener.status != silly_transport::IoStatus.Ready {
        return ServerResult {
            ok: false,
            error: ServerError.Listen,
            system_error: listener.error,
            ..
        };
    }
    var wake = silly_transport::wake_pair();
    if wake.status != silly_transport::IoStatus.Ready {
        silly_transport::close(listener.descriptor);
        return ServerResult {
            ok: false,
            error: ServerError.Wake,
            system_error: wake.error,
            ..
        };
    }
    let result = run_runtime(options, listener.descriptor, wake.reader, seed, W);
    silly_transport::close(wake.writer);
    return result;
}
