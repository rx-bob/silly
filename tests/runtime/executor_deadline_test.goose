// A lane dequeues an already-expired task and publishes Deadline without entering its callback.
namespace executor_deadline_test;

import silly from "../../";

import std;

import.executor_socket_fixture;

fn run() {
    let options = silly::ExecutorOptions {
        lanes: 2,
        independent_lanes: true,
        queue_max: 1,
        outstanding_per_owner: 1,
        ..
    };
    silly::initialize_executor_mailboxes(options, 1);
    qlimit<executor_socket::Started>(1);
    qlimit<executor_socket::Stopped>(1);
    qlimit<executor_socket::Began>(1);
    var control = silly_transport::wake_pair();
    var owner = silly_transport::wake_pair();
    var reports = silly_transport::wake_pair();
    assert(control.status == silly_transport::IoStatus.Ready);
    assert(owner.status == silly_transport::IoStatus.Ready);
    assert(reports.status == silly_transport::IoStatus.Ready);
    let start = silly::LaneStart {
        options: options,
        server: silly::WorkerOptions {
        },
        lane: 0,
        wake: control.reader.fd,
        owner_writers: [owner.writer.fd, -1, -1, -1],
        report_wake: reports.writer.fd,
    };
    let thread = thread_spawn(executor_socket::lane_worker, start, 0);
    control.reader.fd = -1;
    let started, ready = qget<silly::ExecutorReport>(10000);
    assert(ready);
    assert(started.ready);
    assert(started.ok);
    submit_expired(control.writer);
    let reply, present = qget<silly::ExecReply<silly::IoOwner0>>(10000);
    assert(present);
    assert(reply.outcome == silly::ExecutionOutcome.Deadline);
    assert(reply.key.request_generation == 9);
    let began, ran = qpoll<executor_socket::Began>();
    assert(!ran);
    silly::route_executor_stop(0, control.writer);
    assert(thread_wait(thread));
    let stopped, ended = qget<silly::ExecutorReport>(10000);
    assert(ended);
    assert(!stopped.ready);
    assert(stopped.ok);
    let app, has_app = qget<executor_socket::Stopped>(10000);
    assert(has_app);
    assert(app.app.handlers == 0);
    assert(app.app.transfers == 0);
    silly_transport::close(control.writer);
    silly_transport::close(owner.reader);
    silly_transport::close(owner.writer);
    silly_transport::close(reports.reader);
    silly_transport::close(reports.writer);
}

fn submit_expired(wake: silly_transport::Descriptor) {
    assert(qput(silly::LaneTask<silly::ExecutorLane0> {
            work: silly::ExecWork {
                key: silly::TransferKey {
                    owner: 0,
                    slot: 0,
                    connection_generation: 1,
                    request_generation: 9,
                },
                lane: 0,
                deadline_ms: 0,
                head: "POST /first HTTP/1.1\r\nHost: x\r\n\r\n",
                ..
            }
        }));
    assert(silly_transport::notify(wake).status == silly_transport::IoStatus.Ready);
}

fn::main() {
    executor_deadline_test::run();
    print("expired queued executor work never invokes a handler");
}
