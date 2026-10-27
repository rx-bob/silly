// Executor owners share only copied messages and borrowed wake descriptor numbers.
namespace silly;

import std;

import.executor;
import.executor_types;
import.runtime;
import.runtime_mailbox;
import.runtime_monitor;
import.server_options;
import.transport;
import.worker_message;
import.worker_options;

// W and X are concrete application thread_fn entrypoints. The seed is copied into each owner.
fn run_runtime_with_executor<C, W, X>(options: RuntimeOptions, listener: silly_transport::Descriptor,
    wake: silly_transport::Descriptor, seed: C) -> ServerResult {
    var listeners: silly_transport::Descriptor[1] = [listener];
    return run_runtime_listeners_with_executor(options, listeners, wake, seed, W, X);
}

fn run_runtime_listeners_with_executor<C, W, X>(options: RuntimeOptions,
    listeners: silly_transport::Descriptor[:], wake: silly_transport::Descriptor, seed: C) -> ServerResult {
    fn spawn_lanes(settings: RuntimeOptions, workers: RuntimeWorker[:], lanes: RuntimeWorker[:],
        report_wake: i32, config: C, epoch: i64) {
        let writers = runtime_owner_writers(workers);
        for lane in lanes.len {
            lanes[lane].thread = thread_spawn_contained(X, LaneStart {
                    control_epoch: epoch,
                    options: settings.executor,
                    server: settings.worker,
                    lane: lane,
                    wake: lanes[lane].reader.fd,
                    owner_writers: writers,
                    report_wake: report_wake,
                }, config);
            lanes[lane].reader.fd = -1;
            start_runtime_monitor(lanes[lane], true, lane, report_wake);
        }
    }
    return run_runtime_entry(options, listeners, wake, seed, true, W, spawn_lanes);
}

fn runtime_owner_writers(owners: RuntimeWorker[:]) -> i32[4] {
    var writers: i32[4] = [-1; 4];
    for index in owners.len {
        writers[index] = owners[index].writer.fd;
    }
    return writers;
}

fn open_runtime_owners(workers: RuntimeWorker[:], lanes: RuntimeWorker[:]) -> ServerResult {
    let opened = open_runtime_workers(workers);
    if !opened.ok {
        return opened;
    }
    let executors = open_runtime_workers(lanes);
    if !executors.ok {
        close_runtime_owners(workers);
    }
    return executors;
}

fn close_runtime_owners(owners: RuntimeWorker[:]) {
    for &owner in owners {
        silly_transport::close(owner.reader);
        silly_transport::close(owner.writer);
    }
}

fn discard_runtime_executor_replies<Tag>(capacity: i64) {
    for index in capacity {
        let reply, present = qpoll<ExecReply<Tag>>();
        if !present {
            break;
        }
    }
}

fn reclaim_runtime_executor_mailboxes(options: ExecutorOptions) {
    for lane in 4 {
        discard_executor_tasks(lane, options.queue_max);
    }
    discard_runtime_executor_replies<IoOwner0>(options.outstanding_per_owner);
    discard_runtime_executor_replies<IoOwner1>(options.outstanding_per_owner);
    discard_runtime_executor_replies<IoOwner2>(options.outstanding_per_owner);
    discard_runtime_executor_replies<IoOwner3>(options.outstanding_per_owner);
}

fn executor_result(report: ExecutorReport) -> ServerResult {
    return ServerResult {
        ok: report.ok,
        error: report.error,
        message: if report.ok {
            ""
        } else {
            "executor lane failed"
        },
        route_issue: report.route_issue,
        hook_failure: report.hook_failure,
        ..
    };
}
