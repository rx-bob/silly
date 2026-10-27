// Blocking lane callbacks cannot stop their I/O owner, and reverse completions stay addressed.
namespace executor_server_test;

import silly from "..";

import std;

import.body_socket_fixture;
import.connection_socket_fixture;
import.executor_socket_fixture;

fn progress_and_reverse_completion() {
    var running = executor_socket::start();
    var first = body_socket::connect(running.port);
    executor_socket::inline_request(first, 0, "first-warm");
    var second = body_socket::connect(running.port);
    executor_socket::inline_request(second, 1, "second-warm");
    var independent = body_socket::connect(running.port);
    executor_socket::inline_request(independent, 0, "third-warm");
    executor_socket::send_lane(first, 0, "first");
    executor_socket::began(0, "first");
    // Same I/O owner remains responsive while its selected lane is blocked inside the callback.
    executor_socket::inline_request(independent, 0, "still-responsive");
    executor_socket::send_lane(second, 1, "second");
    executor_socket::began(1, "second");
    executor_socket::release(1);
    executor_socket::lane_response(second, 1, "second");
    executor_socket::inline_request(second, 1, "second-reused");
    executor_socket::release(0);
    executor_socket::lane_response(first, 0, "first");
    executor_socket::inline_request(first, 0, "first-reused");
    executor_socket::finish(running, 2);
    silly_transport::close(first);
    silly_transport::close(second);
    silly_transport::close(independent);
}

fn bounded_input_and_output() {
    var running = executor_socket::start();
    var first = body_socket::connect(running.port);
    let body: u8[513] = ['x'; 513];
    executor_socket::send_lane(first, 0, "too-large", body);
    connection_socket::exact(connection_socket::receive(first), 1, 413, "");
    silly_transport::close(first);
    var second = body_socket::connect(running.port);
    body_socket::send_bytes(second, connection_socket::request("POST", "/large"));
    connection_socket::exact(connection_socket::receive(second), 1, 500, "from-lane");
    silly_transport::close(second);
    executor_socket::finish(running, 1);
}

fn queue_expiration() {
    var running = executor_socket::start(500);
    var active = body_socket::connect(running.port);
    executor_socket::inline_request(active, 0, "active");
    var queued = body_socket::connect(running.port);
    executor_socket::inline_request(queued, 1, "queued");
    executor_socket::send_lane(active, 0, "blocked");
    executor_socket::began(0, "blocked");
    executor_socket::send_lane(queued, 0, "expired-before-start");
    connection_socket::exact(connection_socket::receive(queued), 1, 504, "");
    connection_socket::exact(connection_socket::receive(active), 1, 504, "");
    // This releases only the running callback. The queued deadline must skip its handler.
    executor_socket::release(0);
    executor_socket::finish(running, 1);
    silly_transport::close(active);
    silly_transport::close(queued);
}

fn running_shutdown() {
    var running = executor_socket::start();
    var socket = body_socket::connect(running.port);
    executor_socket::send_lane(socket, 0, "shutdown");
    executor_socket::began(0, "shutdown");
    assert(silly_transport::notify(running.wake).status == silly_transport::IoStatus.Ready);
    // Joining cannot finish while a callback owns its admitted work.
    let done, completed = qpoll<executor_socket::RuntimeDone>();
    assert(!completed);
    executor_socket::release(0);
    executor_socket::joined(running, 1);
    silly_transport::close(socket);
}

fn disconnect_and_late_completion() {
    var running = executor_socket::start();
    var old = body_socket::connect(running.port);
    executor_socket::inline_request(old, 0, "old");
    var other = body_socket::connect(running.port);
    executor_socket::inline_request(other, 1, "other");
    executor_socket::send_lane(old, 0, "stale");
    executor_socket::began(0, "stale");
    silly_transport::close(old);
    let cancelled, present = qget<executor_socket::Cancelled>(10000);
    assert(present);
    assert(cancelled.owner == 0);
    // The cancelled slot is now free, but its old executor still owns the old generation.
    var replacement = body_socket::connect(running.port);
    executor_socket::inline_request(replacement, 0, "replacement");
    executor_socket::send_lane(replacement, 1, "current");
    executor_socket::began(1, "current");
    executor_socket::release(0);
    let handled, finished = qget<executor_socket::LaneHandled>(10000);
    assert(finished);
    assert(handled.lane == 0);
    let fds: i32[1] = [replacement.fd];
    let interests: i32[1] = [silly_transport::READ];
    var events: i32[1] = [0];
    assert(silly_transport::poll(fds, interests, events, 50).status == silly_transport::IoStatus.Ready);
    assert(events[0] == 0);
    executor_socket::release(1);
    executor_socket::lane_response(replacement, 1, "current");
    executor_socket::inline_request(replacement, 0, "after-stale");
    executor_socket::finish(running, 2);
    silly_transport::close(other);
    silly_transport::close(replacement);
}

fn owner_credit_refusal() {
    var running = executor_socket::start();
    var first = body_socket::connect(running.port);
    executor_socket::inline_request(first, 0, "first");
    var odd_first = body_socket::connect(running.port);
    executor_socket::inline_request(odd_first, 1, "odd-first");
    var second = body_socket::connect(running.port);
    executor_socket::inline_request(second, 0, "second");
    var odd_second = body_socket::connect(running.port);
    executor_socket::inline_request(odd_second, 1, "odd-second");
    var refused = body_socket::connect(running.port);
    executor_socket::inline_request(refused, 0, "third");
    executor_socket::send_lane(first, 0, "credit-one");
    executor_socket::began(0, "credit-one");
    executor_socket::send_lane(second, 1, "credit-two");
    executor_socket::began(1, "credit-two");
    executor_socket::send_lane(refused, 0, "refused");
    connection_socket::exact(connection_socket::receive(refused), 1, 503, "");
    executor_socket::release(0);
    executor_socket::release(1);
    executor_socket::lane_response(first, 0, "credit-one");
    executor_socket::lane_response(second, 1, "credit-two");
    executor_socket::finish(running, 2);
    silly_transport::close(first);
    silly_transport::close(second);
    silly_transport::close(odd_first);
    silly_transport::close(odd_second);
    silly_transport::close(refused);
}

fn::main() {
    executor_server_test::progress_and_reverse_completion();
    executor_server_test::bounded_input_and_output();
    executor_server_test::queue_expiration();
    executor_server_test::running_shutdown();
    executor_server_test::disconnect_and_late_completion();
    executor_server_test::owner_credit_refusal();
    print("executor isolation, addressed completion, limits, deadlines and shutdown passed");
}
