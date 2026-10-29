// A pre-close publication permit keeps a stopping lane alive until its owned task is enqueued.
namespace shutdown_submission_test;

import native_bindings from "../../examples/promptnook_contract";
import silly from "../../";

import std;

import.native_control;
import.shutdown_socket_fixture;

struct LaneFixture {
    epoch: i64,
    thread: i64,
    control: silly_transport::PairResult,
    owner: silly_transport::PairResult,
    reports: silly_transport::PairResult,
    resource: shutdown_socket::ForeignResource,
}

fn start() -> LaneFixture {
    assert(native_control::native_test_reset(0) == 0);
    qlimit<shutdown_socket::Started>(1);
    qlimit<shutdown_socket::Stopped>(1);
    qlimit<shutdown_socket::ForeignResource>(1);
    qlimit<shutdown_socket::Began>(1);
    let options = shutdown_socket::options(5000);
    silly::initialize_executor_mailboxes(options.executor, 1);
    var control = silly_transport::wake_pair();
    let owner = silly_transport::wake_pair();
    let reports = silly_transport::wake_pair();
    assert(control.status == silly_transport::IoStatus.Ready);
    assert(owner.status == silly_transport::IoStatus.Ready);
    assert(reports.status == silly_transport::IoStatus.Ready);
    let epoch = silly::runtime_control_begin();
    assert(epoch > 0);
    assert(silly::runtime_control_claim_ticket(epoch, 0));
    let launch = silly::LaneStart {
        control_epoch: epoch,
        options: options.executor,
        server: options.worker,
        lane: 0,
        wake: control.reader.fd,
        owner_writers: [owner.writer.fd, -1, -1, -1],
        report_wake: reports.writer.fd,
    };
    let thread = thread_spawn(shutdown_socket::lane_worker, launch, 0);
    control.reader.fd = -1;
    let ready, reported = qget<silly::ExecutorReport>(10000);
    assert(reported);
    assert(ready.ready);
    assert(ready.ok);
    let started, has_started = qget<shutdown_socket::Started>(10000);
    assert(has_started);
    let resource, has_resource = qget<shutdown_socket::ForeignResource>(10000);
    assert(has_resource);
    return LaneFixture {
        epoch: epoch,
        thread: thread,
        control: control,
        owner: owner,
        reports: reports,
        resource: resource,
    };
}

fn run() {
    var lane = start();
    assert(silly::runtime_control_submit_begin(lane.epoch));
    silly::runtime_control_close(lane.epoch);
    assert(!silly::runtime_control_submit_begin(lane.epoch));
    silly::route_executor_stop(0, lane.control.writer);
    let premature, stopped_early = qget<shutdown_socket::Stopped>(50);
    assert(!stopped_early);
    shutdown_socket::resource_open(lane.resource);
    assert(silly::runtime_control_submissions(lane.epoch) == 1);
    // This is the enqueue already authorized before closure, deliberately published after Stop.
    assert(qput(silly::LaneTask<silly::ExecutorLane0> {
            work: silly::ExecWork {
                key: silly::TransferKey {
                    owner: 0,
                    slot: 0,
                    connection_generation: 1,
                    request_generation: 7,
                },
                lane: 0,
                deadline_ms: 0x7fffffffffffffff,
                ..
            }
        }));
    silly::runtime_control_submit_end(lane.epoch);
    let reply, delivered = qget<silly::ExecReply<silly::IoOwner0>>(10000);
    assert(delivered);
    assert(reply.key.request_generation == 7);
    assert(reply.outcome == silly::ExecutionOutcome.Abandoned);
    finish(lane);
}

fn finish(lane: LaneFixture&) {
    assert(thread_wait(lane.thread));
    let stopped, has_stopped = qget<shutdown_socket::Stopped>(10000);
    assert(has_stopped);
    assert(stopped.lane == 0);
    let final, reported = qget<silly::ExecutorReport>(10000);
    assert(reported);
    assert(!final.ready);
    assert(final.ok);
    let began, ran = qpoll<shutdown_socket::Began>();
    assert(!ran);
    let residual, stranded = qpoll<silly::LaneTask<silly::ExecutorLane0>>();
    assert(!stranded);
    assert(silly::runtime_control_submissions(lane.epoch) == 0);
    assert(native_control::native_test_metric(1) == 1);
    shutdown_socket::close_peer(lane.resource);
    silly_transport::close(lane.control.writer);
    silly_transport::close(lane.owner.reader);
    silly_transport::close(lane.owner.writer);
    silly_transport::close(lane.reports.reader);
    silly_transport::close(lane.reports.writer);
    silly::runtime_control_finish(lane.epoch, false);
}

fn::main() {
    shutdown_submission_test::run();
    print("lane shutdown waits for pre-close publication and abandons its queued task");
}
