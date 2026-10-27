// A single supervisor owns admission; up to four independent I/O owners consume addressed queues.
namespace silly;

import std;

import.executor;
import.runtime_control;
import.runtime_executor;
import.runtime_listeners;
import.runtime_mailbox;
import.runtime_monitor;
import.runtime_supervisor;
import.server_options;
import.shutdown;
import.shutdown_types;
import.transport;
import.worker_message;
import.worker_options;

// Single-listener convenience; the group form also carries listener_id into each request.
fn run_runtime<C, W>(options: RuntimeOptions, listener: silly_transport::Descriptor,
    wake: silly_transport::Descriptor, seed: C) -> ServerResult {
    var listeners: silly_transport::Descriptor[1] = [listener];
    return run_runtime_listeners(options, listeners, wake, seed, W);
}

fn run_runtime_listeners<C, W>(options: RuntimeOptions, listeners: silly_transport::Descriptor[:],
    wake: silly_transport::Descriptor, seed: C) -> ServerResult {
    fn no_lanes(settings: RuntimeOptions, workers: RuntimeWorker[:], lanes: RuntimeWorker[:],
        report_wake: i32, config: C, epoch: i64) {
    }
    return run_runtime_entry(options, listeners, wake, seed, false, W, no_lanes);
}

fn run_runtime_entry<C, W, S>(options: RuntimeOptions, listeners: silly_transport::Descriptor[:],
    wake: silly_transport::Descriptor, seed: C, executor: bool) -> ServerResult {
    var control = wake;
    var result = ServerResult {
        ok: false,
        error: ServerError.InvalidOptions,
        message: "invalid runtime options",
        ..
    };
    if valid_runtime_options(options) && (executor || options.executor.lanes == 0)
        && valid_runtime_listeners(listeners, wake) {
        qlimit<RuntimeLease>(1);
        if qput(RuntimeLease {
            }) {
            result = runtime_owned(options, listeners, control, seed, W, S);
            if result.drain == DrainStatus.None {
                let lease, held = qpoll<RuntimeLease>();
                assert(held);
            }
        } else {
            result.error = if runtime_control_poisoned() {
                ServerError.WorkerAborted
            } else {
                ServerError.ShutdownBusy
            };
            result.message = "runtime ownership is retained or poisoned";
        }
    }
    close_runtime_inputs(listeners, control);
    return result;
}

fn runtime_owned<C, W, S>(options: RuntimeOptions, listeners: silly_transport::Descriptor[:],
    wake: silly_transport::Descriptor, seed: C) -> ServerResult {
    initialize_runtime_mailboxes(options.accept_queue_max);
    initialize_executor_mailboxes(options.executor, options.workers);
    qlimit<RuntimeExit>(8);
    var handle = ShutdownHandle {
        worker_count: options.workers,
        lane_count: options.executor.lanes,
        accept_capacity: options.accept_queue_max,
        task_capacity: options.executor.queue_max,
        reply_capacity: options.executor.outstanding_per_owner,
        ..
    };
    let opened = open_shutdown_owners(handle);
    if !opened.ok {
        return opened;
    }
    handle.epoch = runtime_control_begin();
    if handle.epoch <= 0 {
        close_runtime_owners(handle.workers);
        close_runtime_owners(handle.lanes);
        silly_transport::close(handle.reports_reader);
        silly_transport::close(handle.reports_writer);
        return invalid_shutdown_result(ServerError.ShutdownBusy);
    }
    handle.active = true;
    let epoch = handle.epoch;
    let report_wake = handle.reports_writer.fd;
    S(options, handle.workers[..options.workers], handle.lanes[..options.executor.lanes], report_wake, seed, epoch);
    spawn_runtime_workers(options, handle.workers[..options.workers], handle.lanes[..options.executor.lanes],
        report_wake, seed, epoch, W);
    let result = runtime_supervise(options, listeners, wake, handle);
    remember_shutdown_result(handle, result);
    runtime_control_close(epoch);
    close_runtime_listeners(listeners);
    begin_runtime_drain(handle);
    if !result.ok {
        runtime_control_cancel(epoch);
        notify_shutdown_owners(handle);
    }
    return resume_shutdown(handle, options.shutdown_timeout_ms);
}

fn open_shutdown_owners(handle: ShutdownHandle&) -> ServerResult {
    var reports = silly_transport::wake_pair();
    if reports.status != silly_transport::IoStatus.Ready {
        return ServerResult {
            ok: false,
            error: ServerError.Wake,
            system_error: reports.error,
            ..
        };
    }
    let opened = open_runtime_owners(handle.workers[..handle.worker_count], handle.lanes[..handle.lane_count]);
    if !opened.ok {
        silly_transport::close(reports.reader);
        silly_transport::close(reports.writer);
        return opened;
    }
    handle.reports_reader = reports.reader;
    handle.reports_writer = reports.writer;
    return opened;
}

fn spawn_runtime_workers<C, W>(options: RuntimeOptions, workers: RuntimeWorker[:],
    lanes: RuntimeWorker[:], report_wake: i32, seed: C, epoch: i64) {
    let writers = runtime_owner_writers(lanes);
    for owner in workers.len {
        workers[owner].thread = thread_spawn_contained(W, WorkerStart {
                control_epoch: epoch,
                options: options.worker,
                owner: owner,
                wake: workers[owner].reader.fd,
                report_wake: report_wake,
                executor: options.executor,
                lane_writers: writers,
            }, seed);
        workers[owner].reader.fd = -1;
        start_runtime_monitor(workers[owner], false, owner, report_wake);
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
