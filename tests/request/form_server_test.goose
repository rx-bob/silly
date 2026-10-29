// Real form submission runs the example endpoint, enforces limits, and redirects.
namespace form_server_test;

import form_routes from "../../examples";
import silly from "../../";

import std;

import.body_socket_fixture;

struct Stopped {
    ok: bool,
    submissions: i64
}

thread_fn serve(listener: i32, wake: i32) {
    var app = form_example::App {
    };
    var entries: silly::RouteEntry<form_example::Route>[>..] = [];
    var segments: silly::RouteSegment[>..] = [];
    var bytes: u8[>..] = [];
    var router = silly::Router<form_example::Route> {
        entries: entries,
        segments: segments,
        bytes: bytes,
        ..
    };
    form_example::routes(router, app);
    let plan = silly::prepare(router);
    assert(plan.issue.error == silly::RouteError.None);
    let options = silly::ServerOptions {
        port: 0,
        limits: silly::Limits {
            body_bytes_max: 1024,
            output_bytes_max: 512,
            ..
        },
        connections_max: 2,
        response_head_bytes_max: 256,
        buffer_bytes_max: 128 * 1024,
        work_bytes_per_turn: 7,
        accepts_per_turn: 2,
        poll_timeout_ms: 10,
        ..
    };
    assert(silly::valid_server_options(options));
    let result = silly::run_prepared_server(options,
        silly_transport::Descriptor {
            fd: listener
        }, silly_transport::Descriptor {
            fd: wake
        },
        plan, app, form_example::handle);
    assert(qput(Stopped {
            ok: result.ok,
            submissions: app.submissions
        }));
}

fn request(port: i32, path: u8[:], body: u8[:], media: u8[:] = "application/x-www-form-urlencoded") -> u8[>..] {
    var socket = body_socket::connect(port);
    body_socket::send_bytes(socket, str("POST ", path, " HTTP/1.1\r\nHost: localhost\r\n",
        "Connection: close\r\nContent-Type: ", media,
        "\r\nContent-Length: ", body.len, "\r\n\r\n", body));
    let response = body_socket::receive_closed(socket);
    silly_transport::close(socket);
    return response;
}

fn exact(response: u8[:], status: i32, body: u8[:]) {
    assert(starts_with(response, str("HTTP/1.1 ", status, " ")));
    let end = find(response, "\r\n\r\n");
    assert(end >= 0);
    assert(response[end + 4..] == body);
}

fn thanks(port: i32) {
    var socket = body_socket::connect(port);
    body_socket::send_bytes(socket, "GET /thanks HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    exact(body_socket::receive_closed(socket), 200, "Thanks, Ada Lovelace!");
    silly_transport::close(socket);
}

fn verify(port: i32) {
    let submitted = request(port, "/submit", "name=Ada+Lovelace&name=ignored");
    exact(submitted, 303, "");
    assert(find(submitted, "Location: /thanks\r\n") >= 0);
    thanks(port);
    exact(request(port, "/submit", "name=%GG"), 400, "");
    thanks(port);
    exact(request(port, "/submit", "name=x", "text/plain"), 415, "");
    thanks(port);
    exact(request(port, "/submit", "name="), 400, "Name is required");
    thanks(port);
    var repeated: u8[>..] = [];
    for index in 33 {
        if index > 0 {
            repeated.append("&");
        }
        repeated.append("a=b");
    }
    exact(request(port, "/submit", repeated), 413, "");
    thanks(port);
    let excessive: u8[513] = ['x'; 513];
    exact(request(port, "/submit", excessive), 413, "");
    thanks(port);
    var huge = body_socket::connect(port);
    body_socket::send_bytes(huge, str("POST /submit HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n",
        "Content-Type: application/x-www-form-urlencoded\r\nContent-Length: 1025\r\n",
        "Expect: 100-continue\r\n\r\n"));
    let rejected = body_socket::receive_closed(huge);
    exact(rejected, 413, "");
    assert(find(rejected, "100 Continue") < 0);
    silly_transport::close(huge);
    thanks(port);
}

fn run() {
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
    verify(port.count as i32);
    assert(silly_transport::notify(wake.writer).status == silly_transport::IoStatus.Ready);
    let stopped, present = qget<Stopped>(body_socket::DEADLINE_MS);
    assert(present);
    assert(stopped.ok);
    assert(stopped.submissions == 1);
    assert(thread_wait(worker));
    silly_transport::close(wake.writer);
    print("form submit and redirect sockets passed");
}

fn::main() {
    form_server_test::run();
}
