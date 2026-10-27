// Real body admission, continue negotiation, bounded binary collection and rejection isolation.
namespace http_body_server_test;

import silly from "..";

import std;

import.body_socket_fixture;

var handled: i64 = 0;

type Context = silly::Context<silly::NoState, silly::NoStream>;
enum Route {
    Large,
    Empty,
    Small
}
struct Handled {
    number: i64
}
struct Stopped {
    ok: bool,
    handled: i64
}

fn define(router: silly::Router<Route>&) {
    router.post("/large", Route.Large);
    router.post("/none", Route.Empty);
    router.post("/fixed-zero", Route.Empty);
    router.post("/chunked-zero", Route.Empty);
    router.post("/small", Route.Small, silly::RouteOptions {
            body_bytes_max: 3,
            ..
        });
}

fn check_body(ctx: Context&, route: Route, bytes: u8[:]) {
    match route {
        Large => {
            assert(bytes.len == 262145);
            for index in bytes.len {
                assert(bytes[index] == (index % 251)as u8);
            }
        },
        Small => {
            assert(bytes == "abc");
        },
        Empty => {
            assert(bytes.len == 0);
            if ctx.request.target == "/none" {
                assert(ctx.request.body_framing == silly::BodyFraming.None);
            } else if ctx.request.target == "/fixed-zero" {
                assert(ctx.request.body_framing == silly::BodyFraming.Fixed);
            } else {
                assert(ctx.request.body_framing == silly::BodyFraming.Chunked);
            }
        },
    }
}

fn handle(ctx: Context&, route: Route) {
    match silly::body_view(ctx) {
        Available body => {
            check_body(ctx, route, body.bytes);
        },
        Failed _ => {
            assert(false);
        },
    }
    handled += 1;
    assert(qput(Handled {
            number: handled
        }));
    assert(silly::begin_response(ctx.response, 200) == silly::ResponseError.None);
    assert(silly::append_body(ctx.response, "ok") == silly::ResponseError.None);
    assert(silly::prepare_response(ctx.response) == silly::ResponseError.None);
}

thread_fn serve(listener: i32, wake: i32) {
    var entries: silly::RouteEntry<Route>[>..] = [];
    var segments: silly::RouteSegment[>..] = [];
    var bytes: u8[>..] = [];
    var router = silly::Router<Route> {
        entries: entries,
        segments: segments,
        bytes: bytes,
        ..
    };
    define(router);
    let plan = silly::prepare(router);
    assert(plan.issue.error == silly::RouteError.None);
    let options = silly::ServerOptions {
        port: 0,
        limits: silly::Limits {
            body_bytes_max: 300000,
            output_bytes_max: 32,
            ..
        },
        connections_max: 4,
        response_head_bytes_max: 256,
        buffer_bytes_max: 2 * 1024 * 1024,
        work_bytes_per_turn: 17,
        accepts_per_turn: 4,
        idle_timeout_ms: 500,
        poll_timeout_ms: 10,
        body_limits: silly::BodyLimits {
            bytes_max: 300000,
            ..
        },
        body_read_bytes_max: 257,
        ..
    };
    let result = silly::run_prepared_server(options, silly_transport::Descriptor {
            fd: listener
        },
        silly_transport::Descriptor {
            fd: wake
        }, plan, handle);
    assert(qput(Stopped {
            ok: result.ok,
            handled: handled
        }));
}

fn counted(expected: i64) {
    let event, present = qget<Handled>(body_socket::DEADLINE_MS);
    assert(present);
    assert(event.number == expected);
}

fn simple(port: i32, request: u8[:], expected: i64, minor: i32 = 1) {
    var client = body_socket::connect(port);
    body_socket::send_bytes(client, request);
    body_socket::valid_response(client, minor);
    counted(expected);
    silly_transport::close(client);
}

fn large_bodies(port: i32) {
    var payload: u8[>..] = [];
    for index in 262145 {
        payload.push((index % 251)as u8);
    }
    var client = body_socket::connect(port);
    body_socket::send_bytes(client,
        "POST /large HTTP/1.1\r\nHost: x\r\nConnection: close\r\nContent-Length: 262145\r\n\r\n");
    body_socket::send_bytes(client, payload);
    body_socket::valid_response(client);
    counted(1);
    silly_transport::close(client);
    client = body_socket::connect(port);
    body_socket::send_bytes(client,
        "POST /large HTTP/1.1\r\nHost: x\r\nConnection: close\r\nTransfer-Encoding: chunked\r\n\r\n");
    let prefix = "40001;name=\"quoted;value\"\r\n";
    for index in prefix.len {
        body_socket::send_bytes(client, prefix[index..index + 1]);
    }
    body_socket::send_bytes(client, payload);
    let end = "\r\n0;last=yes\r\nX-Checksum: ignored\r\n\r\n";
    for index in end.len {
        body_socket::send_bytes(client, end[index..index + 1]);
    }
    body_socket::valid_response(client);
    counted(2);
    silly_transport::close(client);
}

fn empty_bodies(port: i32) {
    simple(port, "POST /none HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", 3);
    simple(port, "POST /fixed-zero HTTP/1.1\r\nHost: x\r\nConnection: close\r\nContent-Length: 0\r\n\r\n", 4);
    simple(port, str("POST /chunked-zero HTTP/1.1\r\nHost: x\r\nConnection: close\r\n",
        "Transfer-Encoding: chunked\r\n\r\n0\r\n\r\n"), 5);
}

fn continue_body(port: i32) {
    var client = body_socket::connect(port);
    body_socket::send_bytes(client,
        "POST /small HTTP/1.1\r\nHost: x\r\nConnection: close\r\nContent-Length: 3\r\nExpect: 100-continue\r\n\r\n");
    body_socket::interim(client);
    let event, present = qpoll<Handled>();
    assert(!present);
    body_socket::send_bytes(client, "abc");
    body_socket::valid_response(client);
    counted(6);
    silly_transport::close(client);
    simple(port, "POST /small HTTP/1.0\r\nContent-Length: 3\r\nExpect: 100-continue\r\n\r\nabc", 7, 0);
}

fn reject_bodies(port: i32) {
    body_socket::rejected(port,
        "POST /small HTTP/1.1\r\nHost: x\r\nContent-Length: 4\r\nExpect: 100-continue\r\n\r\n", 413);
    body_socket::rejected(port,
        "POST /small HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\nExpect: magic\r\n\r\n", 417);
    body_socket::rejected(port,
        "POST /absent HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\nExpect: 100-continue\r\n\r\n", 404);
    body_socket::rejected(port,
        "POST /small HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nabcd\r\n0\r\n\r\n", 413);
    body_socket::rejected(port,
        "POST /small HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\ng\r\n", 400);
    let event, present = qpoll<Handled>();
    assert(!present);
}

fn unfinished_bodies(port: i32) {
    var client = body_socket::connect(port);
    body_socket::send_bytes(client, "POST /small HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\na");
    silly_transport::close(client);
    client = body_socket::connect(port);
    body_socket::send_bytes(client, "POST /small HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n3\r\na");
    // A stalled body renders a timeout at the inactivity deadline without dispatch.
    let response = body_socket::receive_closed(client);
    assert(starts_with(response, "HTTP/1.1 408 "));
    assert(find(response, "Connection: close\r\n") >= 0);
    silly_transport::close(client);
    let event, present = qpoll<Handled>();
    assert(!present);
    simple(port, "POST /small HTTP/1.1\r\nHost: x\r\nConnection: close\r\nContent-Length: 3\r\n\r\nabc", 8);
}

fn run() {
    qlimit<Handled>(16);
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
    large_bodies(port.count as i32);
    empty_bodies(port.count as i32);
    continue_body(port.count as i32);
    reject_bodies(port.count as i32);
    unfinished_bodies(port.count as i32);
    assert(silly_transport::notify(wake.writer).status == silly_transport::IoStatus.Ready);
    let stopped, present = qget<Stopped>(body_socket::DEADLINE_MS);
    assert(present);
    assert(stopped.ok);
    assert(stopped.handled == 8);
    assert(thread_wait(worker));
    silly_transport::close(wake.writer);
    print("request body socket contracts passed");
}

fn::main() {
    http_body_server_test::run();
}
