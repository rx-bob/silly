// FIN and inactivity expose classified failures only while a response can safely be sent.
namespace http_connection_errors_test;

import silly from "../../";

import std;

import.body_socket_fixture;
import.connection_socket_fixture;

extern fn silly_test_finish_input(fd: i32) -> i32;

struct Stopped {
    ok: bool,
}

fn handle(ctx: silly::Context<silly::NoState, silly::NoStream> & ) {
    ctx.respond_text(200, "ok");
}

fn render(response: silly::Response&, failure: silly::ResponseFailure) {
    assert(qput(failure));
    assert(response.phase == silly::ResponsePhase.Empty);
    if failure.kind == silly::ResponseFailureKind.Admission {
        // Deliberate renderer failure: exactly one empty 500 fallback, then close.
        return;
    }
    assert(silly::begin_response(response, failure.status) == silly::ResponseError.None);
    assert(silly::append_body(response, "classified") == silly::ResponseError.None);
    assert(silly::prepare_response(response) == silly::ResponseError.None);
}

thread_fn serve(listener: i32, wake: i32) {
    let options = silly::ServerOptions {
        limits: silly::Limits {
            head_bytes_max: 512,
            body_bytes_max: 32,
            output_bytes_max: 128,
            ..
        },
        connections_max: 2,
        response_head_bytes_max: 512,
        buffer_bytes_max: 64 * 1024,
        work_bytes_per_turn: 7,
        accepts_per_turn: 2,
        idle_timeout_ms: 250,
        poll_timeout_ms: 10,
        ..
    };
    let result = silly::run_server_with_errors(options,
        silly_transport::Descriptor {
            fd: listener
        },
        silly_transport::Descriptor {
            fd: wake
        }, handle, render);
    assert(qput(Stopped {
            ok: result.ok
        }));
}

fn failure(port: i32, input: u8[:], eof: bool, body: bool, minor: i32) {
    var socket = body_socket::connect(port);
    body_socket::send_bytes(socket, input);
    if eof {
        assert(silly_test_finish_input(socket.fd) == 0);
    }
    let response = body_socket::receive_closed(socket);
    connection_socket::exact(response, minor, if eof {
            400
        } else {
            408
        }, "classified");
    assert(find(response, "Connection: close\r\n") >= 0);
    let event, present = qget<silly::ResponseFailure>(1000);
    assert(present);
    if eof {
        assert(event.transport_status == silly_transport::IoStatus.Closed);
        if body {
            assert(event.kind == silly::ResponseFailureKind.RequestBody);
            assert(event.body_error == silly::BodyStatus.Truncated);
        } else {
            assert(event.kind == silly::ResponseFailureKind.RequestHead);
            assert(event.head_error == silly::HeadResult.Truncated);
        }
    } else {
        assert(event.kind == silly::ResponseFailureKind.Timeout);
    }
    silly_transport::close(socket);
}

fn quiet(port: i32) {
    var socket = body_socket::connect(port);
    assert(silly_test_finish_input(socket.fd) == 0);
    connection_socket::closed(socket);
    silly_transport::close(socket);
    socket = body_socket::connect(port);
    body_socket::send_bytes(socket, "GET / HTTP/1.1\r\nHost: x\r\n\r\n");
    let response = connection_socket::receive(socket);
    connection_socket::exact(response, 1, 200, "ok");
    connection_socket::closed(socket);
    silly_transport::close(socket);
    let event, present = qpoll<silly::ResponseFailure>();
    assert(!present);
}

fn fallback(port: i32) {
    var socket = body_socket::connect(port);
    body_socket::send_bytes(socket, "POST / HTTP/1.0\r\nContent-Length: 100\r\n\r\n");
    let response = body_socket::receive_closed(socket);
    connection_socket::exact(response, 0, 500, "");
    assert(find(response, "Connection: close\r\n") >= 0);
    let event, present = qget<silly::ResponseFailure>(1000);
    assert(present);
    assert(event.kind == silly::ResponseFailureKind.Admission);
    assert(event.status == 501);
    silly_transport::close(socket);
}

fn run() {
    qlimit<silly::ResponseFailure>(16);
    qlimit<Stopped>(1);
    var listener = silly_transport::listen("127.0.0.1", 0, 8);
    assert(listener.status == silly_transport::IoStatus.Ready);
    let port = silly_transport::local_port(listener.descriptor);
    assert(port.status == silly_transport::IoStatus.Ready);
    var wake = silly_transport::wake_pair();
    assert(wake.status == silly_transport::IoStatus.Ready);
    let worker = thread_spawn(serve, listener.descriptor.fd, wake.reader.fd);
    listener.descriptor.fd = -1;
    wake.reader.fd = -1;
    let number = port.count as i32;
    failure(number, "GET / HTTP/1.0\r\nX-Partial: yes", true, false, 0);
    failure(number, "GET / HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\na", true, true, 1);
    failure(number, "GET / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n3\r\na", true, true, 1);
    failure(number, "GET / HTTP/1.0\r\nX-Partial: yes", false, false, 0);
    failure(number, "GET / HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\na", false, true, 1);
    quiet(number);
    fallback(number);
    assert(silly_transport::notify(wake.writer).status == silly_transport::IoStatus.Ready);
    let stopped, present = qget<Stopped>(1000);
    assert(present);
    assert(stopped.ok);
    assert(thread_wait(worker));
    silly_transport::close(wake.writer);
}

fn::main() {
    http_connection_errors_test::run();
    print("connection EOF, timeout and renderer fallback passed");
}
