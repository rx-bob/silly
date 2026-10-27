// Isolated process: a contained owner abort cannot run Stop or recover arbitrary native resources.
namespace shutdown_abort_test;

import silly from "..";

import std;

import.body_socket_fixture;
import.connection_socket_fixture;
import.shutdown_socket_fixture;

fn run() {
    var running = shutdown_socket::start(1);
    var client = body_socket::connect(running.port);
    body_socket::send_bytes(client, connection_socket::request("GET", "/blocking"));
    let began, entered = qget<shutdown_socket::Began>(10000);
    assert(entered);
    let returned = shutdown_socket::returned(running);
    assert(!returned.ok);
    assert(returned.error == silly::ServerError.WorkerAborted);
    assert(returned.drain == silly::DrainStatus.Failed);
    assert(returned.unrecovered_owners != 0);
    assert(!returned.pending.active);
    let stopped, io_stopped = qget<shutdown_socket::Stopped>(10000);
    assert(io_stopped);
    assert(stopped.lane == -1);
    let extra, lane_stopped = qpoll<shutdown_socket::Stopped>();
    assert(!lane_stopped);
    assert(shutdown_socket::native_test_metric(1) == 0);
    shutdown_socket::resource_open(running.foreign);
    poisoned_restart();
    // The fixture knows this raw descriptor; the runtime correctly made no arbitrary cleanup claim.
    var orphan = silly_transport::Descriptor {
        fd: running.foreign.owned_fd
    };
    assert(silly_transport::close(orphan).status == silly_transport::IoStatus.Ready);
    shutdown_socket::close_peer(running.foreign);
    silly_transport::close(client);
    silly_transport::close(running.wake);
}

fn poisoned_restart() {
    var listener = silly_transport::listen("127.0.0.1", 0, 4);
    assert(listener.status == silly_transport::IoStatus.Ready);
    var wake = silly_transport::wake_pair();
    assert(wake.status == silly_transport::IoStatus.Ready);
    let result = silly::run_runtime_with_executor(shutdown_socket::options(50), listener.descriptor, wake.reader,
        0, shutdown_socket::io_worker, shutdown_socket::lane_worker);
    listener.descriptor.fd = -1;
    wake.reader.fd = -1;
    assert(!result.ok);
    assert(result.error == silly::ServerError.WorkerAborted);
    assert(!result.pending.active);
    let extra, restarted = qpoll<shutdown_socket::Started>();
    assert(!restarted);
    silly_transport::close(wake.writer);
}

fn::main() {
    shutdown_abort_test::run();
    print("aborted owner reports failed drain without claiming native cleanup or Stop");
}
