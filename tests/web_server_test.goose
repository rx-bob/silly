// The example completes a persistent form round-trip with text and attribute escaping.
namespace web_server_test;

import silly from "..";
import web_routes from "../examples";

import std;

import.body_socket_fixture;
import.connection_socket_fixture;

struct Stopped {
    ok: bool,
    submissions: i64,
}

thread_fn serve(listener: i32, wake: i32) {
    var app = web_example::App {
    };
    var entries: silly::RouteEntry<web_example::Route>[>..] = [];
    var segments: silly::RouteSegment[>..] = [];
    var bytes: u8[>..] = [];
    var router = silly::Router<web_example::Route> {
        entries: entries,
        segments: segments,
        bytes: bytes,
        ..
    };
    web_example::routes(router, app);
    let plan = silly::prepare(router);
    assert(plan.issue.error == silly::RouteError.None);
    let options = silly::ServerOptions {
        limits: silly::Limits {
            body_bytes_max: 1024,
            output_bytes_max: 4096,
            ..
        },
        connections_max: 2,
        response_head_bytes_max: 512,
        buffer_bytes_max: 128 * 1024,
        work_bytes_per_turn: 7,
        accepts_per_turn: 2,
        poll_timeout_ms: 10,
        ..
    };
    let result = silly::run_prepared_server(options,
        silly_transport::Descriptor {
            fd: listener
        },
        silly_transport::Descriptor {
            fd: wake
        }, plan, app, web_example::handle);
    assert(qput(Stopped {
            ok: result.ok,
            submissions: app.submissions
        }));
}

fn page(response: u8[:]) {
    assert(starts_with(response, "HTTP/1.1 200 "));
    assert(find(response, "Content-Type: text/html; charset=utf-8\r\n") >= 0);
    assert(find(response, "<form action=\"/submit\" method=\"post\">") >= 0);
    assert(find(response, "<input name=\"name\" value=\"\">") >= 0);
}

fn verify(port: i32) {
    var socket = body_socket::connect(port);
    body_socket::send_bytes(socket, connection_socket::request("GET", "/"));
    page(connection_socket::receive(socket));
    let payload = "name=%22%27%3E%3Cscript%3Ealert%281%29%3C%2Fscript%3E%26";
    body_socket::send_bytes(socket, connection_socket::request("POST", "/submit", 1,
        "Content-Type: application/x-www-form-urlencoded\r\n", payload));
    let redirect = connection_socket::receive(socket);
    connection_socket::exact(redirect, 1, 303, "");
    assert(find(redirect, "Location: /thanks\r\n") >= 0);
    assert(find(redirect, "Content-Type:") < 0);
    for invalid in["name=%00", "name=%FF"] {
        body_socket::send_bytes(socket, connection_socket::request("POST", "/submit", 1,
            "Content-Type: application/x-www-form-urlencoded\r\n", invalid));
        connection_socket::exact(connection_socket::receive(socket), 1, 400, "Name must be valid UTF-8 text");
    }
    body_socket::send_bytes(socket, connection_socket::request("GET", "/thanks"));
    let thanks = connection_socket::receive(socket);
    assert(find(thanks, "<h1>Thanks, \"'&gt;&lt;script&gt;alert(1)&lt;/script&gt;&amp;!</h1>") >= 0);
    assert(find(thanks, "<script>") < 0);
    body_socket::send_bytes(socket, connection_socket::request("GET", "/", 1, "Connection: close\r\n"));
    let filled = connection_socket::receive(socket);
    assert(find(filled, "value=\"&quot;&#39;&gt;&lt;script&gt;alert(1)&lt;/script&gt;&amp;\"") >= 0);
    assert(find(filled, "<script>") < 0);
    connection_socket::closed(socket);
    silly_transport::close(socket);
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
    let stopped, present = qget<Stopped>(1000);
    assert(present);
    assert(stopped.ok);
    assert(stopped.submissions == 1);
    assert(thread_wait(worker));
    silly_transport::close(wake.writer);
}

fn::main() {
    web_server_test::run();
    print("HTML form, redirect and escaped reflection passed");
}
