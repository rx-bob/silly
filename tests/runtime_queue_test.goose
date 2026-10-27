// Accepted descriptors have exactly one owner across bounded mailbox handoff and reclamation.
namespace runtime_queue_test;

import silly from "..";

import std;

struct First {
}
struct Second {
}

fn peer_closed(socket: silly_transport::Descriptor) {
    var bytes: u8[1] = [0];
    assert(silly_transport::read(socket, bytes).status == silly_transport::IoStatus.Closed);
}

fn bounded_handoff() {
    qlimit<silly::AcceptMessage<First>>(1);
    qlimit<silly::AcceptMessage<Second>>(1);
    var wake = silly_transport::wake_pair();
    var first = silly_transport::wake_pair();
    var second = silly_transport::wake_pair();
    assert(wake.status == silly_transport::IoStatus.Ready);
    assert(first.status == silly_transport::IoStatus.Ready);
    assert(second.status == silly_transport::IoStatus.Ready);
    let first_fd = first.reader.fd;
    assert(silly::publish_accept<First>(wake.writer, first.reader) == silly::PublishResult.Queued);
    assert(first.reader.fd == -1);
    let second_fd = second.reader.fd;
    assert(silly::publish_accept<First>(wake.writer, second.reader) == silly::PublishResult.Full);
    assert(second.reader.fd == second_fd);
    // A distinct static owner mailbox remains independently available.
    assert(silly::publish_accept<Second>(wake.writer, second.reader) == silly::PublishResult.Queued);
    assert(second.reader.fd == -1);
    assert(silly_transport::drain_wake(wake.reader).status == silly_transport::IoStatus.Ready);
    let accepted, present = qpoll<silly::AcceptMessage<Second>>();
    assert(present);
    assert(accepted.fd == second_fd);
    var owned = silly_transport::Descriptor {
        fd: accepted.fd
    };
    silly_transport::close(owned);
    peer_closed(second.writer);
    let other, exists = qpoll<silly::AcceptMessage<First>>();
    assert(exists);
    assert(other.fd == first_fd);
    owned = silly_transport::Descriptor {
        fd: other.fd
    };
    silly_transport::close(owned);
    peer_closed(first.writer);
    assert(silly::discard_accepts<First>(1) == 0);
    assert(silly::discard_accepts<Second>(1) == 0);
    silly_transport::close(first.writer);
    silly_transport::close(second.writer);
    silly_transport::close(wake.reader);
    silly_transport::close(wake.writer);
}

fn failed_notification_reclaimed() {
    qlimit<silly::AcceptMessage<First>>(2);
    var first = silly_transport::wake_pair();
    var second = silly_transport::wake_pair();
    assert(first.status == silly_transport::IoStatus.Ready);
    assert(second.status == silly_transport::IoStatus.Ready);
    let gone = silly_transport::Descriptor {
    };
    assert(silly::publish_accept<First>(gone, first.reader) == silly::PublishResult.QueuedOwnerGone);
    assert(silly::publish_accept<First>(gone, second.reader) == silly::PublishResult.QueuedOwnerGone);
    assert(first.reader.fd == -1);
    assert(second.reader.fd == -1);
    // Producer and reader are quiescent. Supervisor closes every accepted resource exactly once.
    assert(silly::discard_accepts<First>(1) == 1);
    peer_closed(first.writer);
    assert(silly::discard_accepts<First>(2) == 1);
    peer_closed(second.writer);
    assert(silly::discard_accepts<First>(2) == 0);
    silly_transport::close(first.writer);
    silly_transport::close(second.writer);
}

fn connection_slots_and_turn_budget() {
    qlimit<silly::AcceptMessage<First>>(2);
    var first = silly_transport::wake_pair();
    var second = silly_transport::wake_pair();
    assert(first.status == silly_transport::IoStatus.Ready);
    assert(second.status == silly_transport::IoStatus.Ready);
    assert(qput(silly::AcceptMessage<First> {
            fd: first.reader.fd
        }));
    assert(qput(silly::AcceptMessage<First> {
            fd: second.reader.fd
        }));
    first.reader.fd = -1;
    second.reader.fd = -1;
    var connections: silly::Connection[1] = [silly::Connection {
        }];
    assert(silly::drain_worker_accepts<First>(connections, 1, 123));
    assert(connections[0].socket.fd >= 0);
    assert(connections[0].generation == 1);
    assert(connections[0].active_ms == 123);
    assert(connections[0].phase == silly::ConnectionPhase.Reading);
    // Full slots refuse the next handoff, and the bounded drain forces a no-sleep next turn.
    assert(silly::drain_worker_accepts<First>(connections, 1, 124));
    peer_closed(second.writer);
    assert(!silly::drain_worker_accepts<First>(connections, 1, 125));
    silly::release_connection(connections[0]);
    peer_closed(first.writer);
    silly_transport::close(first.writer);
    silly_transport::close(second.writer);
}

fn::main() {
    runtime_queue_test::bounded_handoff();
    runtime_queue_test::failed_notification_reclaimed();
    runtime_queue_test::connection_slots_and_turn_budget();
    print("accepted socket ownership, saturation and reclamation passed");
}
