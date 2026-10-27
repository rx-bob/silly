// Flat snapshots and distinct lane queues enforce admission and owner credit independently.
namespace executor_queue_test;

import silly from "..";

import std;

fn work(owner: i64, lane: i64, slot: i64 = 0) -> silly::ExecWork {
    let clock = silly_transport::monotonic_ms();
    assert(clock.status == silly_transport::IoStatus.Ready);
    return silly::ExecWork {
        key: silly::TransferKey {
            owner: owner,
            slot: slot,
            connection_generation: 1,
            request_generation: 1,
        },
        lane: lane,
        deadline_ms: clock.count + 10000,
        head: "GET /work HTTP/1.1\r\nHost: x\r\n\r\n",
        body: "owned",
        ..
    };
}

fn admission_and_copy() {
    let options = silly::ExecutorOptions {
        lanes: 2,
        independent_lanes: true,
        queue_max: 1,
        outstanding_per_owner: 2,
        ..
    };
    silly::initialize_executor_mailboxes(options, 2);
    var wake = silly_transport::wake_pair();
    assert(wake.status == silly_transport::IoStatus.Ready);
    var owner = silly::ExecutorOwner {
        options: options,
        owner: 0,
        lane_writers: [wake.writer.fd, wake.writer.fd, -1, -1],
        ..
    };
    var snapshot = work(0, 0);
    assert(silly::submit_executor(owner, snapshot) == silly::ExecutionOutcome.Queued);
    assert(owner.outstanding == 1);
    snapshot.body.clear();
    snapshot.body.append("mutated");
    assert(silly::submit_executor(owner, work(0, 0, 1)) == silly::ExecutionOutcome.QueueFull);
    assert(owner.outstanding == 1);
    assert(silly::submit_executor(owner, work(1, 1)) == silly::ExecutionOutcome.Unavailable);
    assert(owner.outstanding == 1);
    assert(silly::submit_executor(owner, work(0, 1, 1)) == silly::ExecutionOutcome.Queued);
    assert(owner.outstanding == 2);
    let first, has_first = qpoll<silly::LaneTask<silly::ExecutorLane0>>();
    assert(has_first);
    assert(first.work.body == "owned");
    assert(first.work.key.owner == 0);
    // Lane zero is free, but the owner still holds two outstanding response credits.
    assert(silly::submit_executor(owner, work(0, 0, 2)) == silly::ExecutionOutcome.QueueFull);
    let second, has_second = qpoll<silly::LaneTask<silly::ExecutorLane1>>();
    assert(has_second);
    assert(second.work.key.slot == 1);
    assert(silly_transport::drain_wake(wake.reader).status == silly_transport::IoStatus.Ready);
    silly_transport::close(wake.reader);
    silly_transport::close(wake.writer);
}

fn limits_and_deadlines() {
    var owner = silly::ExecutorOwner {
        options: silly::ExecutorOptions {
            lanes: 1,
            head_bytes_max: 8,
            body_bytes_max: 2,
            ..
        },
        owner: 0,
        ..
    };
    assert(silly::submit_executor(owner, work(0, 0)) == silly::ExecutionOutcome.InputLimit);
    var small = work(0, 0);
    small.head.clear();
    assert(silly::submit_executor(owner, small) == silly::ExecutionOutcome.InputLimit);
    small.body.clear();
    small.deadline_ms = 0;
    assert(silly::submit_executor(owner, small) == silly::ExecutionOutcome.Deadline);
    small.key.request_generation = 0;
    assert(silly::submit_executor(owner, small) == silly::ExecutionOutcome.Unavailable);
    assert(owner.outstanding == 0);
}

fn::main() {
    executor_queue_test::admission_and_copy();
    executor_queue_test::limits_and_deadlines();
    print("executor snapshots, targeted queues, credit refusal and limits passed");
}
