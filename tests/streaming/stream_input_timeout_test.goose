// The absolute input body deadline remains active while a producer waits for bytes.
namespace stream_input_timeout_test;

import silly from "../../";

import std;

import.body_socket_fixture;
import.stream_http_fixture;

fn run() {
    qlimit<stream_http::Started>(1);
    qlimit<stream_http::Began>(1);
    qlimit<stream_http::Released>(1);
    qlimit<stream_http::Finished>(1);
    qlimit<stream_http::Stopped>(1);
    var listener = silly_transport::listen("127.0.0.1", 0, 8);
    assert(listener.status == silly_transport::IoStatus.Ready);
    let port = silly_transport::local_port(listener.descriptor);
    var wake = silly_transport::wake_pair();
    let worker = thread_spawn(stream_http::serve, listener.descriptor.fd, wake.reader.fd, 100);
    listener.descriptor.fd = -1;
    wake.reader.fd = -1;
    let start, started = qget<stream_http::Started>(10000);
    assert(started);
    check_request(port.count as i32);
    assert(silly_transport::notify(wake.writer).status == silly_transport::IoStatus.Ready);
    let stop, stopped = qget<stream_http::Stopped>(10000);
    assert(stopped);
    assert(stop.ok);
    assert(thread_wait(worker));
    silly_transport::close(wake.writer);
}

fn check_request(port: i32) {
    var socket = body_socket::connect(port);
    body_socket::send_bytes(socket,
        "POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 3\r\n\r\n");
    let begin, began = qget<stream_http::Began>(10000);
    assert(began);
    let response = body_socket::receive_closed(socket);
    assert(starts_with(response, "HTTP/1.1 408 "));
    let released, cleanup = qget<stream_http::Released>(10000);
    assert(cleanup);
    assert(released.cancelled);
    assert(released.failed);
    assert(released.bytes == 0);
    let done, finished = qget<stream_http::Finished>(10000);
    assert(finished);
    assert(done.data.timeout == silly::TimeoutKind.Body);
    let extra, duplicate = qpoll<stream_http::Released>();
    assert(!duplicate);
    silly_transport::close(socket);
}

fn::main() {
    stream_input_timeout_test::run();
    print("streamed input timeout releases producer exactly once");
}
