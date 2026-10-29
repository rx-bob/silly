// Distinct owner queues, enqueue-before-wake, bounded refusal and shutdown races with real threads.
namespace queue_routing_test;

import silly from "../../";

import std;

let WAIT_MS = 5000;

struct FirstOwner {
}
struct SecondOwner {
}
struct LateOwner {
}
struct CoalescedOwner {
}
struct OwnerGo<O> {
    value: bool
}
struct OwnerReport<O> {
    count: i64,
    total: i64
}
struct ProducerReport {
    count: i64
}
struct LateReady {
    value: bool
}
struct LateGo {
    value: bool
}
struct LateReport {
    result: silly::PublishResult
}
struct StopGo {
    value: bool
}
struct Stopped {
    value: bool
}

fn key(owner: i64, request: u64 = 1) -> silly::TransferKey {
    return silly::TransferKey {
        owner: owner,
        slot: 0,
        connection_generation: 1,
        request_generation: request
    };
}

fn completion<O>(owner: i64, value: i32) -> silly::WorkCompletion<O> {
    return silly::WorkCompletion<O> {
        key: key(owner),
        code: value,
        bytes: "owned",
        ..
    };
}

// Startup chooses this finite tag table. Runtime owner IDs never select an arbitrary shared mailbox.
fn dispatch(work: silly::WorkMessage, first: silly_transport::Descriptor,
    second: silly_transport::Descriptor) -> silly::PublishResult {
    if work.key.owner == 0 {
        return silly::publish_completion(0, first, silly::WorkCompletion<FirstOwner> {
                key: work.key,
                code: work.operation,
                bytes: work.bytes,
            });
    }
    if work.key.owner == 1 {
        return silly::publish_completion(1, second, silly::WorkCompletion<SecondOwner> {
                key: work.key,
                code: work.operation,
                bytes: work.bytes,
            });
    }
    return silly::PublishResult.WrongOwner;
}

thread_fn producer(first: i32, second: i32) {
    for index in 3 {
        let work, present = qget<silly::WorkMessage>(WAIT_MS);
        assert(present);
        let result = dispatch(work, silly_transport::Descriptor {
                fd: first
            },
            silly_transport::Descriptor {
                fd: second
            });
        assert(result == silly::PublishResult.Queued);
    }
    assert(qput(ProducerReport {
            count: 3
        }));
}

fn consume_owner<O>(owner_id: i64, reader: i32, expected: i64) {
    let go, present = qget<OwnerGo<O>>(WAIT_MS);
    assert(present);
    assert(go.value);
    var socket = silly_transport::Descriptor {
        fd: reader
    };
    let fds: i32[1] = [reader];
    let interests: i32[1] = [silly_transport::READ];
    var events: i32[1] = [0];
    assert(silly_transport::poll(fds, interests, events, 0).status == silly_transport::IoStatus.Ready);
    assert((events[0] & silly_transport::READ) != 0);
    assert(silly_transport::drain_wake(socket).status == silly_transport::IoStatus.Ready);
    var total = 0;
    for index in expected {
        let result, received = qpoll<silly::WorkCompletion<O>>();
        assert(received);
        assert(result.key.owner == owner_id);
        assert(result.bytes == "owned");
        total += result.code;
    }
    let extra, received = qpoll<silly::WorkCompletion<O>>();
    assert(!received);
    assert(silly_transport::close(socket).status == silly_transport::IoStatus.Ready);
    assert(qput(OwnerReport<O> {
            count: expected,
            total: total
        }));
}

thread_fn first_owner(reader: i32) {
    consume_owner<FirstOwner>(0, reader, 2);
}

thread_fn second_owner(reader: i32) {
    consume_owner<SecondOwner>(1, reader, 1);
}

fn send_work(owner_id: i64, operation: i32) {
    var temporary: u8[..silly::WORK_BYTES_MAX] = [];
    temporary.append("owned");
    assert(qput(silly::WorkMessage {
            key: key(owner_id),
            operation: operation,
            bytes: temporary
        }));
    temporary.clear();
    temporary.append("changed after queue copy");
}

fn targeted_delivery() {
    qlimit<silly::WorkMessage>(3);
    qlimit<silly::WorkCompletion<FirstOwner>>(2);
    qlimit<silly::WorkCompletion<SecondOwner>>(1);
    qlimit<OwnerGo<FirstOwner>>(1);
    qlimit<OwnerGo<SecondOwner>>(1);
    qlimit<OwnerReport<FirstOwner>>(1);
    qlimit<OwnerReport<SecondOwner>>(1);
    qlimit<ProducerReport>(1);
    var first = silly_transport::wake_pair();
    var second = silly_transport::wake_pair();
    assert(first.status == silly_transport::IoStatus.Ready);
    assert(second.status == silly_transport::IoStatus.Ready);
    let first_worker = thread_spawn(first_owner, first.reader.fd);
    let second_worker = thread_spawn(second_owner, second.reader.fd);
    let worker = thread_spawn(producer, first.writer.fd, second.writer.fd);
    send_work(0, 11);
    send_work(1, 20);
    send_work(0, 12);
    let produced, ready = qget<ProducerReport>(WAIT_MS);
    assert(ready);
    assert(produced.count == 3);
    assert(thread_wait(worker));
    verify_refusal(first);
    assert(qput(OwnerGo<SecondOwner> {
            value: true
        }));
    let second_report, second_done = qget<OwnerReport<SecondOwner>>(WAIT_MS);
    assert(second_done);
    assert(second_report.count == 1);
    assert(second_report.total == 20);
    assert(thread_wait(second_worker));
    assert(qput(OwnerGo<FirstOwner> {
            value: true
        }));
    let first_report, first_done = qget<OwnerReport<FirstOwner>>(WAIT_MS);
    assert(first_done);
    assert(first_report.count == 2);
    assert(first_report.total == 23);
    assert(thread_wait(first_worker));
    first.reader.fd = -1;
    second.reader.fd = -1;
    silly_transport::close(first.writer);
    silly_transport::close(second.writer);
}

fn verify_refusal(first: silly_transport::PairResult) {
    assert(silly::publish_completion(0, first.writer, completion<FirstOwner>(1, 99))
        == silly::PublishResult.WrongOwner);
    assert(silly::publish_completion(0, first.writer, completion<FirstOwner>(0, 99))
        == silly::PublishResult.Full);
}

thread_fn cancelled_owner(reader: i32) {
    let go, present = qget<StopGo>(WAIT_MS);
    assert(present);
    assert(go.value);
    var socket = silly_transport::Descriptor {
        fd: reader
    };
    assert(silly_transport::close(socket).status == silly_transport::IoStatus.Ready);
    assert(qput(Stopped {
            value: true
        }));
}

thread_fn late_producer(writer: i32) {
    let work, present = qget<silly::WorkMessage>(WAIT_MS);
    assert(present);
    assert(qput(LateReady {
            value: true
        }));
    let go, proceed = qget<LateGo>(WAIT_MS);
    assert(proceed);
    assert(go.value);
    var socket = silly_transport::Descriptor {
        fd: writer
    };
    let result = silly::publish_completion(2, socket, silly::WorkCompletion<LateOwner> {
            key: work.key,
            code: work.operation,
            bytes: work.bytes,
        });
    assert(silly_transport::close(socket).status == silly_transport::IoStatus.Ready);
    assert(qput(LateReport {
            result: result
        }));
}

fn shutdown_race() {
    qlimit<silly::WorkCompletion<LateOwner>>(2);
    qlimit<StopGo>(1);
    qlimit<Stopped>(1);
    qlimit<LateReady>(1);
    qlimit<LateGo>(1);
    qlimit<LateReport>(1);
    var wake = silly_transport::wake_pair();
    assert(wake.status == silly_transport::IoStatus.Ready);
    let owner_worker = thread_spawn(cancelled_owner, wake.reader.fd);
    let producer_worker = thread_spawn(late_producer, wake.writer.fd);
    wake.reader.fd = -1;
    wake.writer.fd = -1;
    send_work(2, 30);
    let admitted, admission = qget<LateReady>(WAIT_MS);
    assert(admission);
    assert(admitted.value);
    // Admission now closes. Existing work remains producer-owned until it returns.
    assert(qput(StopGo {
            value: true
        }));
    let stopped, done = qget<Stopped>(WAIT_MS);
    assert(done);
    assert(stopped.value);
    assert(thread_wait(owner_worker));
    assert(qput(LateGo {
            value: true
        }));
    let published, returned = qget<LateReport>(WAIT_MS);
    assert(returned);
    assert(published.result == silly::PublishResult.QueuedOwnerGone);
    assert(thread_wait(producer_worker));
    // Only after both threads stop may the supervisor become the mailbox's reader.
    assert(silly::discard_completions<LateOwner>(2) == 1);
    assert(silly::discard_completions<LateOwner>(2) == 0);
}

fn coalesced_wake() {
    qlimit<silly::WorkCompletion<CoalescedOwner>>(1);
    var wake = silly_transport::wake_pair(4096);
    assert(wake.status == silly_transport::IoStatus.Ready);
    let bytes: u8[4096] = ['x'; 4096];
    var full = false;
    for attempt in 1024 {
        let result = silly_transport::write_parts(wake.writer, bytes, "");
        if result.status == silly_transport::IoStatus.WouldBlock {
            full = true;
            break;
        }
        assert(result.status == silly_transport::IoStatus.Ready);
    }
    assert(full);
    assert(silly::publish_completion(3, wake.writer, completion<CoalescedOwner>(3, 40))
        == silly::PublishResult.Queued);
    assert(silly::retry_completion_wake(wake.writer) == silly::PublishResult.Queued);
    let result, present = qpoll<silly::WorkCompletion<CoalescedOwner>>();
    assert(present);
    assert(result.code == 40);
    assert(silly::discard_completions<CoalescedOwner>(1) == 0);
    silly_transport::close(wake.reader);
    silly_transport::close(wake.writer);
}

fn::main() {
    queue_routing_test::targeted_delivery();
    queue_routing_test::shutdown_race();
    queue_routing_test::coalesced_wake();
    print("targeted queue and shutdown contracts passed");
}
