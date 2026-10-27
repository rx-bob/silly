// Nonblocking admission, addressed completion queues and finite mailbox ownership.
namespace silly;

import std;

import.executor_types;
import.transport;
import.worker_message;

fn initialize_executor_mailboxes(options: ExecutorOptions, owners: i64) {
    assert(valid_executor_options(options));
    assert(owners > 0);
    assert(owners <= 4);
    qlimit<LaneTask<ExecutorLane0>>(options.queue_max);
    qlimit<LaneStop<ExecutorLane0>>(1);
    qlimit<ExecReply<IoOwner0>>(options.outstanding_per_owner);
    qlimit<LaneTask<ExecutorLane1>>(options.queue_max);
    qlimit<LaneStop<ExecutorLane1>>(1);
    qlimit<ExecReply<IoOwner1>>(options.outstanding_per_owner);
    qlimit<LaneTask<ExecutorLane2>>(options.queue_max);
    qlimit<LaneStop<ExecutorLane2>>(1);
    qlimit<ExecReply<IoOwner2>>(options.outstanding_per_owner);
    qlimit<LaneTask<ExecutorLane3>>(options.queue_max);
    qlimit<LaneStop<ExecutorLane3>>(1);
    qlimit<ExecReply<IoOwner3>>(options.outstanding_per_owner);
    qlimit<ExecutorReport>(8);
}

fn submit_executor(owner: ExecutorOwner&, work: ExecWork) -> ExecutionOutcome {
    if owner.owner < 0 || owner.owner >= 4 || !valid_transfer_key(work.key) || work.key.owner != owner.owner
        || work.lane < 0 || work.lane >= owner.options.lanes {
        return ExecutionOutcome.Unavailable;
    }
    if work.head.len > owner.options.head_bytes_max || work.body.len > owner.options.body_bytes_max {
        return ExecutionOutcome.InputLimit;
    }
    if owner.outstanding >= owner.options.outstanding_per_owner {
        return ExecutionOutcome.QueueFull;
    }
    let clock = silly_transport::monotonic_ms();
    if clock.status != silly_transport::IoStatus.Ready {
        return ExecutionOutcome.Unavailable;
    }
    if work.deadline_ms <= clock.count {
        return ExecutionOutcome.Deadline;
    }
    var queued = false;
    if work.lane == 0 {
        queued = qput(LaneTask<ExecutorLane0> {
                work: work
            });
    } else if work.lane == 1 {
        queued = qput(LaneTask<ExecutorLane1> {
                work: work
            });
    } else if work.lane == 2 {
        queued = qput(LaneTask<ExecutorLane2> {
                work: work
            });
    } else if work.lane == 3 {
        queued = qput(LaneTask<ExecutorLane3> {
                work: work
            });
    }
    if !queued {
        return ExecutionOutcome.QueueFull;
    }
    owner.outstanding += 1;
    silly_transport::notify(silly_transport::Descriptor {
            fd: owner.lane_writers[work.lane]
        });
    return ExecutionOutcome.Queued;
}

fn route_executor_stop(lane: i64, writer: silly_transport::Descriptor) {
    if lane == 0 {
        assert(qput(LaneStop<ExecutorLane0> {
            }));
    } else if lane == 1 {
        assert(qput(LaneStop<ExecutorLane1> {
            }));
    } else if lane == 2 {
        assert(qput(LaneStop<ExecutorLane2> {
            }));
    } else if lane == 3 {
        assert(qput(LaneStop<ExecutorLane3> {
            }));
    }
    silly_transport::notify(writer);
}

fn discard_lane_tasks<Tag>(capacity: i64) {
    for index in capacity {
        let task, present = qpoll<LaneTask<Tag>>();
        if !present {
            break;
        }
    }
    let stop, present = qpoll<LaneStop<Tag>>();
}

fn discard_executor_tasks(lane: i64, capacity: i64) {
    if lane == 0 {
        discard_lane_tasks<ExecutorLane0>(capacity);
    } else if lane == 1 {
        discard_lane_tasks<ExecutorLane1>(capacity);
    } else if lane == 2 {
        discard_lane_tasks<ExecutorLane2>(capacity);
    } else if lane == 3 {
        discard_lane_tasks<ExecutorLane3>(capacity);
    }
}

fn publish_executor_report(wake: i32, report: ExecutorReport) {
    assert(qput(report));
    silly_transport::notify(silly_transport::Descriptor {
            fd: wake
        });
}
