// One disposable real listener exercises the combined general web public surface.
namespace general_web_test;

import silly from "..";

import std;

import.body_socket_fixture;
import.files_fixture;
import.general_web_cases;
import.general_web_server;
import.general_web_types;

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
    abort("general web file executor did not finish");
}

fn run() {
    qlimit<general_web::Started>(1);
    qlimit<general_web::Stopped>(1);
    qlimit<general_web::Acquired>(8);
    qlimit<general_web::Released>(8);
    qlimit<general_web::Waiting>(1);
    var path: u8[128] = [0; 128];
    let size = file_fixture::silly_files_fixture_create(path);
    assert(size > 0);
    var root = silly::open_file_root(path[..size]);
    assert(root.ok);
    var pool = silly::start_file_executor(silly::FileExecutorOptions {
            capacity: 2,
            chunk_bytes: 7,
            ..
        });
    assert(pool.ok);
    var listener = silly_transport::listen("127.0.0.1", 0, 8);
    assert(listener.status == silly_transport::IoStatus.Ready);
    let port = silly_transport::local_port(listener.descriptor).count as i32;
    var wake = silly_transport::wake_pair();
    assert(wake.status == silly_transport::IoStatus.Ready);
    let thread = thread_spawn(general_web::serve, listener.descriptor.fd, wake.reader.fd, pool.executor, root.root);
    listener.descriptor.fd = -1;
    wake.reader.fd = -1;
    let started, ready = qget<general_web::Started>(10000);
    assert(ready);
    general_web_cases::buffered(port);
    general_web_cases::streams(port);
    general_web_cases::upload_failures(port);
    general_web_cases::event_limit(port);
    general_web_cases::disconnected(port);
    assert(silly_transport::notify(wake.writer).status == silly_transport::IoStatus.Ready);
    let stopped, done = qget<general_web::Stopped>(10000);
    assert(done);
    assert(stopped.ok);
    assert(stopped.stopped);
    assert(stopped.handlers == 16);
    assert(stopped.completed == stopped.handlers + 2);
    assert(thread_wait(thread));
    silly_transport::close(wake.writer);
    finish(pool.executor);
    assert(silly::close_file_root(root.root).ok);
    assert(file_fixture::silly_files_fixture_remove() == 0);
}

fn::main() {
    general_web_test::run();
    print("combined HTML/form, JSON, file, upload/download and SSE contracts passed");
}
