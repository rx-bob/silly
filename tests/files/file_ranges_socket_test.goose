// Disposable file server drives range and conditional wire contracts.
namespace file_ranges_socket_test;

import silly from "../../";

import std;

import.body_socket_fixture;
import.file_ranges_socket_cases;
import.file_ranges_socket_server;
import.static_metadata_fixture;

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

fn run() {
    qlimit<ranges_server::Started>(1);
    qlimit<ranges_server::Stopped>(1);
    var path: u8[128] = [0; 128];
    let size = static_fixture::silly_metadata_fixture_create(path);
    assert(size > 0);
    var root = silly::open_file_root(path[..size]);
    assert(root.ok);
    var pool = silly::start_file_executor(silly::FileExecutorOptions {
            workers: 2,
            capacity: 4,
            chunk_bytes: 3,
            ..
        });
    assert(pool.ok);
    var listener = silly_transport::listen("127.0.0.1", 0, 8);
    assert(listener.status == silly_transport::IoStatus.Ready);
    let port = silly_transport::local_port(listener.descriptor);
    assert(port.status == silly_transport::IoStatus.Ready);
    var wake = silly_transport::wake_pair();
    assert(wake.status == silly_transport::IoStatus.Ready);
    let owner = thread_spawn(ranges_server::server, listener.descriptor.fd, wake.reader.fd, pool.executor, root.root);
    listener.descriptor.fd = -1;
    wake.reader.fd = -1;
    let started, ready = qget<ranges_server::Started>(10000);
    assert(ready);
    range_cases::single(port.count as i32);
    range_cases::ignored(port.count as i32);
    range_cases::multipart(port.count as i32);
    range_cases::conditions(port.count as i32);
    range_cases::persistent(port.count as i32);
    assert(silly_transport::notify(wake.writer).status == silly_transport::IoStatus.Ready);
    let stopped, done = qget<ranges_server::Stopped>(10000);
    assert(done);
    assert(stopped.ok);
    assert(thread_wait(owner));
    silly_transport::close(wake.writer);
    finish(pool.executor);
    assert(silly::close_file_root(root.root).ok);
    assert(static_fixture::silly_metadata_fixture_remove() == 0);
}

fn::main() {
    file_ranges_socket_test::run();
    print("file range socket selection, multipart framing, conditional ordering and reuse passed");
}
