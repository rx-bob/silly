// Streaming proxy integration verifies forwarding, bounded flow and terminal cleanup.
namespace proxy_test;

import client from "../../client";
import proxy from "../../client";
import silly from "../../";

import std;

import.proxy_failure_cases;
import.proxy_fixture;
import.proxy_server;

fn pause() {
    const fds: i32[1] = [-1];
    const interests: i32[1] = [0];
    var events: i32[1] = [0];
    silly_transport::poll(fds, interests, events, 10);
}

fn run() {
    qlimit<proxy_server::Started>(1);
    qlimit<proxy_server::Stopped>(1);
    var client = silly_client::start_client(silly_client::ClientOptions {
            concurrency_max: 1,
            queue_max: 0,
            connect_timeout_ms: 10000,
            first_byte_timeout_ms: 10000,
            idle_timeout_ms: 10000,
            ..
        });
    assert(client.ok);
    var listener = silly_transport::listen("127.0.0.1", 0, 8);
    assert(listener.status == silly_transport::IoStatus.Ready);
    let port = silly_transport::local_port(listener.descriptor);
    assert(port.status == silly_transport::IoStatus.Ready);
    var wake = silly_transport::wake_pair();
    assert(wake.status == silly_transport::IoStatus.Ready);
    let owner = thread_spawn(proxy_server::server, listener.descriptor.fd, wake.reader.fd, client.client);
    listener.descriptor.fd = -1;
    wake.reader.fd = -1;
    let started, ready = qget<proxy_server::Started>(10000);
    assert(ready);
    assert(proxy_fixture::silly_proxy_ready(port.count as i32) == 0);
    while proxy_fixture::silly_proxy_stop() == 0 {
        pause();
    }
    assert(silly_transport::notify(wake.writer).status == silly_transport::IoStatus.Ready);
    let stopped, done = qget<proxy_server::Stopped>(10000);
    assert(done);
    assert(stopped.ok);
    assert(thread_wait(owner));
    silly_transport::close(wake.writer);
    assert(silly_client::stop_client(client.client).ok);
    for turn in 1000 {
        let result = silly_client::finish_client(client.client);
        assert(result.error == silly_client::ClientError.None);
        if result.complete {
            return;
        }
        pause();
    }
    abort("proxy client shutdown did not finish");
}

fn::main() {
    proxy_failures::commitment();
    proxy_test::run();
}
