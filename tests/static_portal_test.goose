namespace static_portal_test;

import silly from "..";

import std;

import.body_socket_fixture;
import.static_portal_cases;
import.static_portal_fixture;
import.static_portal_server;

fn finish(executor: silly::FileExecutor&) {
    assert(silly::stop_file_executor(executor).ok);
    let deadline = body_socket::now() + 10000;
    while body_socket::now() < deadline {
        let result = silly::finish_file_executor(executor);
        assert(result.error == 0);
        if result.complete {
            return;
        }
        const fds: i32[1] = [-1];
        const interests: i32[1] = [0];
        var events: i32[1] = [0];
        silly_transport::poll(fds, interests, events, 1);
    }
    abort("metadata executor did not finish");
}

fn run(capacity: i32) {
    qlimit<portal_server::Started>(1);
    qlimit<portal_server::Stopped>(1);
    var path: u8[128] = [0; 128];
    let size = portal_fixture::silly_portal_fixture_create(path);
    assert(size > 0);
    var root = silly::open_file_root(path[..size]);
    assert(root.ok);
    var pool = silly::start_file_executor(silly::FileExecutorOptions {
            workers: 2,
            capacity: capacity,
            chunk_bytes: 7,
            ..
        });
    assert(pool.ok);
    var listener = silly_transport::listen("127.0.0.1", 0, 8);
    assert(listener.status == silly_transport::IoStatus.Ready);
    let port = silly_transport::local_port(listener.descriptor);
    assert(port.status == silly_transport::IoStatus.Ready);
    var wake = silly_transport::wake_pair();
    assert(wake.status == silly_transport::IoStatus.Ready);
    let owner = thread_spawn(portal_server::server, listener.descriptor.fd, wake.reader.fd, pool.executor, root.root);
    listener.descriptor.fd = -1;
    wake.reader.fd = -1;
    let started, ready = qget<portal_server::Started>(10000);
    assert(ready);
    if capacity == 1 {
        portal_cases::one_slot_fallback(port.count as i32);
    } else {
        portal_cases::encoding(port.count as i32);
        portal_cases::metadata(port.count as i32);
        portal_cases::compressed_multipart(port.count as i32);
        portal_cases::listings(port.count as i32);
        portal_cases::policies(port.count as i32);
        portal_cases::redirects(port.count as i32);
        portal_cases::persistent(port.count as i32);
        portal_cases::concurrent_listing(port.count as i32);
    }
    assert(silly_transport::notify(wake.writer).status == silly_transport::IoStatus.Ready);
    let stopped, done = qget<portal_server::Stopped>(10000);
    assert(done);
    assert(stopped.ok);
    assert(thread_wait(owner));
    silly_transport::close(wake.writer);
    finish(pool.executor);
    assert(silly::close_file_root(root.root).ok);
    assert(portal_fixture::silly_portal_fixture_remove() == 0);
}

fn::main() {
    static_portal_test::run(4);
    static_portal_test::run(1);
    print("static Portal compression, listing, fallback and redirect contracts passed");
}
