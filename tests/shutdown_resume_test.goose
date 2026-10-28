// Deadline returns a retained owner handle; only release plus resumed drain may close native state.
namespace shutdown_resume_test;

import native_bindings from "../examples/promptnook_contract";
import silly from "..";

import std;

import.body_socket_fixture;
import.connection_socket_fixture;
import.native_control;
import.shutdown_socket_fixture;

struct PendingClients {
    queued: silly_transport::Descriptor,
    partial: silly_transport::Descriptor,
    idle: silly_transport::Descriptor,
}

fn run() {
    var running = shutdown_socket::start();
    assert(native_control::native_test_arm(1) == 0);
    var client = body_socket::connect(running.port);
    body_socket::send_bytes(client, connection_socket::request("GET", "/blocking"));
    assert(native_control::native_test_wait(10000) == 0);
    var pending_clients = queue_and_partial(running.port);
    assert(silly_transport::notify(running.wake).status == silly_transport::IoStatus.Ready);
    let returned = shutdown_socket::returned(running);
    assert(!returned.ok);
    assert(returned.error == silly::ServerError.IncompleteDrain);
    assert(returned.drain == silly::DrainStatus.Incomplete);
    assert(returned.pending.active);
    connection_socket::closed(client);
    connection_socket::closed(pending_clients.queued);
    connection_socket::closed(pending_clients.partial);
    connection_socket::closed(pending_clients.idle);
    shutdown_socket::resource_open(running.foreign);
    assert(native_control::native_test_metric(1) == 0);
    pending_restart_refused();
    var pending = returned.pending;
    var stale = pending;
    let again = silly::resume_shutdown(pending, 10);
    assert(!pending.active);
    assert(again.error == silly::ServerError.IncompleteDrain);
    assert(again.drain == silly::DrainStatus.Incomplete);
    assert(again.pending.active);
    let rejected = silly::resume_shutdown(stale, 10);
    assert(rejected.error == silly::ServerError.InvalidShutdownHandle);
    shutdown_socket::resource_open(running.foreign);
    assert(native_control::native_test_release() == 0);
    var final_handle = again.pending;
    let done = silly::resume_shutdown(final_handle, 10000);
    assert(!final_handle.active);
    assert(done.ok);
    assert(done.drain == silly::DrainStatus.Complete);
    assert(!done.pending.active);
    shutdown_socket::stopped();
    shutdown_socket::close_peer(running.foreign);
    assert(native_control::native_test_metric(3) == 1);
    assert(native_control::native_test_metric(4) == 1);
    silly_transport::close(client);
    silly_transport::close(pending_clients.queued);
    silly_transport::close(pending_clients.partial);
    silly_transport::close(pending_clients.idle);
    silly_transport::close(running.wake);
}

fn queue_and_partial(port: i32) -> PendingClients {
    var first = body_socket::connect(port);
    var second = body_socket::connect(port);
    body_socket::send_bytes(first, connection_socket::request("GET", "/blocking"));
    body_socket::send_bytes(second, connection_socket::request("GET", "/blocking"));
    // One task occupies the only queued credit; either candidate may lose the race and get 503.
    let fds: i32[2] = [first.fd, second.fd];
    let interests: i32[2] = [silly_transport::READ; 2];
    var events: i32[2] = [0; 2];
    assert(silly_transport::poll(fds, interests, events, 1000).status == silly_transport::IoStatus.Ready);
    assert(events[0] != 0 || events[1] != 0);
    var refused = if events[0] != 0 {
        first
    } else {
        second
    };
    let queued = if events[0] != 0 {
        second
    } else {
        first
    };
    connection_socket::exact(connection_socket::receive(refused), 1, 503, "");
    silly_transport::close(refused);
    var partial = body_socket::connect(port);
    body_socket::send_bytes(partial, "GET /inline HTTP/1.1\r\nHost:");
    let idle = body_socket::connect(port);
    return PendingClients {
        queued: queued,
        partial: partial,
        idle: idle
    };
}

fn pending_restart_refused() {
    var listener = silly_transport::listen("127.0.0.1", 0, 4);
    assert(listener.status == silly_transport::IoStatus.Ready);
    var wake = silly_transport::wake_pair();
    assert(wake.status == silly_transport::IoStatus.Ready);
    let result = silly::run_runtime_with_executor(shutdown_socket::options(50), listener.descriptor, wake.reader,
        0, shutdown_socket::io_worker, shutdown_socket::lane_worker);
    listener.descriptor.fd = -1;
    wake.reader.fd = -1;
    assert(!result.ok);
    assert(result.error == silly::ServerError.ShutdownBusy);
    assert(!result.pending.active);
    let extra, restarted = qpoll<shutdown_socket::Started>();
    assert(!restarted);
    silly_transport::close(wake.writer);
}

fn graceful_before_deadline() {
    var running = shutdown_socket::start(2);
    assert(native_control::native_test_arm(1) == 0);
    var client = body_socket::connect(running.port);
    body_socket::send_bytes(client, connection_socket::request("GET", "/blocking"));
    assert(native_control::native_test_wait(10000) == 0);
    assert(silly_transport::notify(running.wake).status == silly_transport::IoStatus.Ready);
    assert(native_control::native_test_release() == 0);
    let returned = shutdown_socket::returned(running);
    assert(returned.ok);
    assert(returned.drain == silly::DrainStatus.Complete);
    assert(!returned.pending.active);
    connection_socket::exact(body_socket::receive_closed(client), 1, 200, "listener:0:377");
    shutdown_socket::stopped();
    shutdown_socket::close_peer(running.foreign);
    assert(native_control::native_test_metric(4) == 1);
    silly_transport::close(client);
    silly_transport::close(running.wake);
}

fn::main() {
    shutdown_resume_test::run();
    shutdown_resume_test::graceful_before_deadline();
    // A complete drain releases the process lease and all fixed mailboxes for the next runtime.
    shutdown_resume_test::run();
    print("bounded incomplete shutdown retains native ownership until resumed drain completes");
}
