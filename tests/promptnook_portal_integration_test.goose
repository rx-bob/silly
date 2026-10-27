// One Portal instance composes static files and streaming proxy, with local upstream and owned cleanup.
namespace portal_join_test;

import adapters from "../examples/promptnook_contract";
import client from "../client";
import native_state from "../examples/promptnook_contract";
import portal_proxy from "../examples/promptnook_contract";
import proxy from "../client";
import silly from "..";

import std;

import.body_socket_fixture;
import.connection_socket_fixture;
import.native_socket_fixture;
import.promptnook_integration_runtime;
import.promptnook_integration_types;
import.promptnook_portal_app;
import.promptnook_portal_join_cases;
import.promptnook_portal_upstream;
import.static_portal_checks;
import.static_portal_fixture;

struct Running {
    thread: i64,
    port: i32,
    wake: silly_transport::Descriptor,
}
fn upstream() -> Running {
    qlimit<portal_upstream::Started>(1);
    qlimit<portal_upstream::Stopped>(1);
    qlimit<portal_upstream::Holding>(2);
    qlimit<portal_upstream::Release>(2);
    var listener = silly_transport::listen("127.0.0.1", 0, 8);
    assert(listener.status == silly_transport::IoStatus.Ready);
    let port = silly_transport::local_port(listener.descriptor).count as i32;
    var wake = silly_transport::wake_pair();
    assert(wake.status == silly_transport::IoStatus.Ready);
    let thread = thread_spawn(portal_upstream::server, listener.descriptor.fd, wake.reader.fd);
    listener.descriptor.fd = -1;
    wake.reader.fd = -1;
    let started, ready = qget<portal_upstream::Started>(10000);
    assert(ready);
    return Running {
        thread: thread,
        port: port,
        wake: wake.writer
    };
}

fn portal(app: portal_integration::AppState) -> Running {
    qlimit<portal_integration::Started>(1);
    qlimit<portal_integration::Stopped>(1);
    qlimit<portal_integration::Completed>(64);
    qlimit<portal_integration::Cancelled>(4);
    var listener = silly_transport::listen("127.0.0.1", 0, 8);
    assert(listener.status == silly_transport::IoStatus.Ready);
    let port = silly_transport::local_port(listener.descriptor).count as i32;
    var wake = silly_transport::wake_pair();
    assert(wake.status == silly_transport::IoStatus.Ready);
    let thread = thread_spawn(portal_integration::server, listener.descriptor.fd, wake.reader.fd, app);
    listener.descriptor.fd = -1;
    wake.reader.fd = -1;
    let started, ready = qget<portal_integration::Started>(10000);
    assert(ready);
    return Running {
        thread: thread,
        port: port,
        wake: wake.writer
    };
}

fn pause() {
    const fds: i32[1] = [-1];
    const interests: i32[1] = [0];
    var events: i32[1] = [0];
    silly_transport::poll(fds, interests, events, 10);
}

fn finish_resources(app: portal_integration::AppState&) {
    assert(silly_client::stop_client(app.client).ok);
    assert(silly::stop_file_executor(app.executor).ok);
    var client_done = false;
    var files_done = false;
    let deadline = body_socket::now() + 10000;
    while !client_done || !files_done {
        assert(body_socket::now() < deadline);
        if !client_done {
            let result = silly_client::finish_client(app.client);
            assert(result.error == silly_client::ClientError.None);
            client_done = result.complete;
        }
        if !files_done {
            let result = silly::finish_file_executor(app.executor);
            assert(result.error == 0);
            files_done = result.complete;
        }
        if !client_done || !files_done {
            pause();
        }
    }
    assert(silly::close_file_root(app.root).ok);
}

fn stop(front: Running&, back: Running&) {
    assert(silly_transport::notify(front.wake).status == silly_transport::IoStatus.Ready);
    let portal_done, portal_finished = qget<portal_integration::Stopped>(10000);
    assert(portal_finished);
    assert(portal_done.ok);
    assert(thread_wait(front.thread));
    assert(silly_transport::notify(back.wake).status == silly_transport::IoStatus.Ready);
    let upstream_done, upstream_finished = qget<portal_upstream::Stopped>(10000);
    assert(upstream_finished);
    assert(upstream_done.ok);
    assert(thread_wait(back.thread));
    silly_transport::close(front.wake);
    silly_transport::close(back.wake);
    var files = 0;
    var proxies = 0;
    while true {
        let done, present = qpoll<portal_integration::Completed>();
        if !present {
            break;
        }
        if done.proxy {
            proxies += 1;
        } else {
            files += 1;
        }
    }
    assert(files == 13);
    assert(proxies == 11);
    let extra, present = qpoll<portal_integration::Cancelled>();
    assert(!present);
}

// Actual streamed Portal remains serviceable while the separate API's native lane is held.
fn native_and_portal(port: i32) {
    var native = pn_integration::start();
    var request = body_socket::connect(native.api);
    assert(native_socket::native_test_arm(1) == 0);
    body_socket::send_bytes(request, connection_socket::request("GET", "/api/workspaces", 1,
        "Authorization: Bearer contract\r\n"));
    assert(native_socket::native_test_wait(10000) == 0);
    portal_checks::file(portal_checks::exchange(port, "GET", "/asset.txt"), false, portal_checks::IDENTITY);
    portal_join_cases::proxy(port);
    assert(native_socket::native_test_metric(3) == 1);
    assert(native_socket::native_test_metric(4) == 0);
    assert(native_socket::native_test_release() == 0);
    connection_socket::exact(connection_socket::receive(request), 1, 200, "listener:0:db:117");
    silly_transport::close(request);
    pn_integration::finish(native);
    assert(native_socket::native_test_metric(4) == 1);
    var completions = 0;
    while true {
        let done, present = qpoll<pn_integration::Finished>();
        if !present {
            break;
        }
        completions += 1;
    }
    assert(completions == 2);
}

fn run() {
    var path: u8[128] = [0; 128];
    let size = portal_fixture::silly_portal_fixture_create(path);
    assert(size > 0);
    var root = silly::open_file_root(path[..size]);
    assert(root.ok);
    var pool = silly::start_file_executor();
    assert(pool.ok);
    var client = silly_client::start_client(silly_client::ClientOptions {
            concurrency_max: 1,
            queue_max: 0,
            ..
        });
    assert(client.ok);
    var back = upstream();
    // Hold the refused port through all listener creation, then close it before the failure case.
    var refused = silly_transport::listen("127.0.0.1", 0, 1);
    assert(refused.status == silly_transport::IoStatus.Ready);
    let refused_port = silly_transport::local_port(refused.descriptor).count;
    var app = portal_integration::AppState {
        executor: pool.executor,
        root: root.root,
        client: client.client,
        ..
    };
    app.upstream_url.append(str("http://127.0.0.1:", back.port, "/api/admin"));
    app.refused_url.append(str("http://127.0.0.1:", refused_port));
    var front = portal(app);
    native_and_portal(front.port);
    silly_transport::close(refused.descriptor);
    portal_join_cases::run(front.port);
    stop(front, back);
    finish_resources(app);
    assert(portal_fixture::silly_portal_fixture_remove() == 0);
}

fn::main() {
    portal_join_test::run();
    print("combined Portal static/proxy, independent I/O and cleanup contracts passed");
}
