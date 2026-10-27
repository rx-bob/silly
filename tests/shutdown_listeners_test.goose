// API and portal listeners share owners and shutdown, while requests retain their listener identity.
namespace shutdown_listeners_test;

import silly from "..";

import std;

import.body_socket_fixture;
import.connection_socket_fixture;
import.shutdown_socket_fixture;

thread_fn supervisor(api: i32, portal: i32, wake: i32) {
    var listeners: silly_transport::Descriptor[2] = [silly_transport::Descriptor {
            fd: api
        },
        silly_transport::Descriptor {
            fd: portal
        }];
    let result = silly::run_runtime_listeners_with_executor(shutdown_socket::options(5000), listeners,
        silly_transport::Descriptor {
            fd: wake
        }, 0, shutdown_socket::io_worker, shutdown_socket::lane_worker);
    assert(qput(shutdown_socket::RuntimeReturned {
            ok: result.ok,
            error: result.error,
            drain: result.drain,
            pending: result.pending,
            unrecovered_owners: result.unrecovered_owners,
        }));
}

fn inline_routes(router: silly::Router<shutdown_socket::Route>&, app: shutdown_socket::App&) {
    router.get("/inline", shutdown_socket::Route.Inline);
}

thread_fn inline_worker(start: silly::WorkerStart, mode: i64) {
    silly::run_runtime_worker<shutdown_socket::Route>(start, mode, shutdown_socket::initialize, inline_routes,
        shutdown_socket::handle, shutdown_socket::lifecycle);
}

thread_fn inline_supervisor(api: i32, portal: i32, wake: i32) {
    var listeners: silly_transport::Descriptor[2] = [silly_transport::Descriptor {
            fd: api
        },
        silly_transport::Descriptor {
            fd: portal
        }];
    let result = silly::run_runtime_listeners(silly::RuntimeOptions {
        }, listeners,
        silly_transport::Descriptor {
            fd: wake
        }, 0, inline_worker);
    assert(qput(shutdown_socket::RuntimeReturned {
            ok: result.ok,
            error: result.error,
            drain: result.drain,
            pending: result.pending,
            unrecovered_owners: result.unrecovered_owners,
        }));
}

fn closed_listener(port: i32) {
    var result = silly_transport::connect("127.0.0.1", port);
    if result.status == silly_transport::IoStatus.WouldBlock {
        body_socket::ready(result.descriptor, silly_transport::WRITE, body_socket::now() + 10000);
        assert(silly_transport::finish_connect(result.descriptor).status != silly_transport::IoStatus.Ready);
    } else {
        assert(result.status != silly_transport::IoStatus.Ready);
    }
    silly_transport::close(result.descriptor);
}

fn requests(api_port: i32, portal_port: i32) {
    var api = body_socket::connect(api_port);
    var portal = body_socket::connect(portal_port);
    body_socket::send_bytes(api, connection_socket::request("GET", "/inline"));
    body_socket::send_bytes(portal, connection_socket::request("GET", "/inline"));
    connection_socket::exact(connection_socket::receive(api), 1, 200, "listener:0");
    connection_socket::exact(connection_socket::receive(portal), 1, 200, "listener:1");
    // Listener metadata is copied through executor admission and reconstruction too.
    body_socket::send_bytes(portal, connection_socket::request("GET", "/blocking"));
    connection_socket::exact(connection_socket::receive(portal), 1, 200, "listener:1:377");
    body_socket::send_bytes(api, connection_socket::request("GET", "/blocking"));
    connection_socket::exact(connection_socket::receive(api), 1, 200, "listener:0:377");
    silly_transport::close(api);
    silly_transport::close(portal);
}

fn run() {
    assert(shutdown_socket::native_test_reset(0) == 0);
    qlimit<shutdown_socket::ForeignResource>(1);
    qlimit<shutdown_socket::Started>(2);
    qlimit<shutdown_socket::Stopped>(2);
    qlimit<shutdown_socket::Began>(8);
    qlimit<shutdown_socket::RuntimeReturned>(1);
    var api = silly_transport::listen("127.0.0.1", 0, 8);
    var portal = silly_transport::listen("127.0.0.1", 0, 8);
    assert(api.status == silly_transport::IoStatus.Ready);
    assert(portal.status == silly_transport::IoStatus.Ready);
    let api_port = silly_transport::local_port(api.descriptor).count as i32;
    let portal_port = silly_transport::local_port(portal.descriptor).count as i32;
    assert(api_port != portal_port);
    var wake = silly_transport::wake_pair();
    assert(wake.status == silly_transport::IoStatus.Ready);
    let thread = thread_spawn(supervisor, api.descriptor.fd, portal.descriptor.fd, wake.reader.fd);
    api.descriptor.fd = -1;
    portal.descriptor.fd = -1;
    wake.reader.fd = -1;
    for index in 2 {
        let started, ready = qget<shutdown_socket::Started>(10000);
        assert(ready);
    }
    let resource, has_resource = qget<shutdown_socket::ForeignResource>(10000);
    assert(has_resource);
    requests(api_port, portal_port);
    assert(silly_transport::notify(wake.writer).status == silly_transport::IoStatus.Ready);
    let returned, present = qget<shutdown_socket::RuntimeReturned>(10000);
    assert(present);
    assert(returned.ok);
    assert(returned.drain == silly::DrainStatus.Complete);
    assert(!returned.pending.active);
    assert(thread_wait(thread));
    shutdown_socket::stopped();
    shutdown_socket::close_peer(resource);
    closed_listener(api_port);
    closed_listener(portal_port);
    silly_transport::close(wake.writer);
}

fn inline_only() {
    qlimit<shutdown_socket::Started>(1);
    qlimit<shutdown_socket::Stopped>(1);
    qlimit<shutdown_socket::RuntimeReturned>(1);
    var api = silly_transport::listen("127.0.0.1", 0, 8);
    var portal = silly_transport::listen("127.0.0.1", 0, 8);
    assert(api.status == silly_transport::IoStatus.Ready);
    assert(portal.status == silly_transport::IoStatus.Ready);
    let api_port = silly_transport::local_port(api.descriptor).count as i32;
    let portal_port = silly_transport::local_port(portal.descriptor).count as i32;
    var wake = silly_transport::wake_pair();
    assert(wake.status == silly_transport::IoStatus.Ready);
    let thread = thread_spawn(inline_supervisor, api.descriptor.fd, portal.descriptor.fd, wake.reader.fd);
    api.descriptor.fd = -1;
    portal.descriptor.fd = -1;
    wake.reader.fd = -1;
    let started, ready = qget<shutdown_socket::Started>(10000);
    assert(ready);
    for index in 2 {
        var client = body_socket::connect(if index == 0 {
                api_port
            } else {
                portal_port
            });
        body_socket::send_bytes(client, connection_socket::request("GET", "/inline"));
        connection_socket::exact(connection_socket::receive(client), 1, 200, str("listener:", index));
        silly_transport::close(client);
    }
    assert(silly_transport::notify(wake.writer).status == silly_transport::IoStatus.Ready);
    let returned, present = qget<shutdown_socket::RuntimeReturned>(10000);
    assert(present);
    assert(returned.ok);
    assert(returned.drain == silly::DrainStatus.Complete);
    assert(thread_wait(thread));
    let stopped, ended = qget<shutdown_socket::Stopped>(10000);
    assert(ended);
    assert(stopped.lane == -1);
    closed_listener(api_port);
    closed_listener(portal_port);
    silly_transport::close(wake.writer);
}

fn::main() {
    shutdown_listeners_test::run();
    shutdown_listeners_test::inline_only();
    print("grouped listeners preserve inline and executor identity and stop through one control");
}
