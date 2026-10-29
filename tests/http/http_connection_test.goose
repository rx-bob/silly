// Real sockets exercise ordered persistence, response ownership and request-local reset.
namespace http_connection_test;

import silly from "../../";

import std;

import.body_socket_fixture;
import.connection_socket_fixture;

struct App {
    calls: i64 = 0,
    cleanups: i64 = 0,
    mutations: i64 = 0,
    active: bool = false,
}
type Context = silly::Context<App, silly::NoStream>;
enum Route {
    Mutate,
    Clean,
    Binary,
    Empty,
    Auth,
    Echo,
}
struct Stopped {
    ok: bool,
    app: App,
}

fn define(router: silly::Router<Route>&) {
    router.post("/mutate/:id", Route.Mutate);
    router.get("/clean", Route.Clean);
    router.get("/binary", Route.Binary);
    router.head("/binary", Route.Binary);
    router.get("/empty", Route.Empty);
    router.post("/auth", Route.Auth);
    router.post("/echo", Route.Echo);
    router.scope("/policy") {
        group =>
        group.policy = silly::RoutePolicy {
            automatic_options: true,
            method_not_allowed: true,
            ..
        };
        group.get("/item", Route.Clean);
    };
}

fn handle(ctx: Context&, route: Route) {
    assert(!ctx.app.active);
    assert(ctx.app.calls == ctx.app.cleanups);
    assert(ctx.response.phase == silly::ResponsePhase.Empty);
    assert(ctx.response.output.len == 0);
    assert(ctx.response.header_fields.len == 0);
    ctx.app.active = true;
    ctx.app.calls += 1;
    match route {
        Mutate => {
            assert(ctx.request.method == "POST");
            assert(ctx.param("id").present);
            assert(ctx.header("X-Request").value == "first");
            ctx.app.mutations += 1;
            assert(silly::begin_response(ctx.response, 201) == silly::ResponseError.None);
            assert(silly::add_header(ctx.response, "X-Previous", "must disappear") == silly::ResponseError.None);
            assert(silly::append_body(ctx.response, str(ctx.param("id").value, ":", ctx.body(), ":",
                ctx.app.mutations)) == silly::ResponseError.None);
            assert(silly::prepare_response(ctx.response) == silly::ResponseError.None);
        },
        Clean => {
            assert(ctx.request.method == "GET");
            assert(!ctx.param("id").present);
            assert(!ctx.header("X-Request").present);
            assert(ctx.body().len == 0);
            ctx.respond_text(200, "clean");
        },
        Binary => {
            assert(silly::begin_response(ctx.response, 200) == silly::ResponseError.None);
            assert(silly::append_body(ctx.response, "a\x00b") == silly::ResponseError.None);
            assert(silly::prepare_response(ctx.response) == silly::ResponseError.None);
        },
        Empty => {
            ctx.respond_empty(204);
        },
        Auth => {
            assert(ctx.body().len > 0);
            silly::reject_text(ctx, 401, "denied");
            abort("auth rejection returned");
        },
        Echo => {
            ctx.respond_text(200, ctx.body());
        },
    }
}

fn cleanup(app: App&, outcome: silly::HandlerOutcome) {
    assert(app.active);
    app.active = false;
    app.cleanups += 1;
}

fn render(response: silly::Response&, failure: silly::ResponseFailure) {
    assert(response.phase == silly::ResponsePhase.Empty);
    assert(response.output.len == 0);
    assert(failure.status == 400);
    let message = if failure.kind == silly::ResponseFailureKind.RequestHead {
        assert(failure.head_error == silly::HeadResult.BadRequest);
        "head rejected"
    } else {
        assert(failure.kind == silly::ResponseFailureKind.RequestBody);
        assert(failure.body_error == silly::BodyStatus.BadFraming);
        "body rejected"
    };
    assert(silly::begin_response(response, 400) == silly::ResponseError.None);
    assert(silly::append_body(response, message) == silly::ResponseError.None);
    assert(silly::prepare_response(response) == silly::ResponseError.None);
}

thread_fn serve(listener: i32, wake: i32, budget: i64) {
    var app = App {
    };
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
        limits: silly::Limits {
            head_bytes_max: 256,
            body_bytes_max: 2048,
            output_bytes_max: 2048,
            ..
        },
        connections_max: 2,
        response_head_bytes_max: 512,
        buffer_bytes_max: 64 * 1024,
        work_bytes_per_turn: budget,
        accepts_per_turn: 2,
        idle_timeout_ms: 3000,
        poll_timeout_ms: 10,
        body_read_bytes_max: 4096,
        ..
    };
    let result = silly::run_prepared_server_with_cleanup_and_errors(options,
        silly_transport::Descriptor {
            fd: listener
        }, silly_transport::Descriptor {
            fd: wake
        }, plan, app, handle, cleanup, render);
    assert(qput(Stopped {
            ok: result.ok,
            app: app,
        }));
}

fn sequential(port: i32, minor: i32) {
    var socket = body_socket::connect(port);
    let keep = if minor == 0 {
        "Connection: extension, KeEp-AlIvE\r\n"
    } else {
        "Connection: extension\r\n"
    };
    let first = connection_socket::request("POST", "/mutate/one", minor,
        str(keep, "X-Request: first\r\n"), "payload");
    body_socket::send_bytes(socket, first[..13]);
    body_socket::send_bytes(socket, first[13..]);
    let response = connection_socket::receive(socket);
    connection_socket::exact(response, minor, 201, if minor == 0 {
            "one:payload:1"
        } else {
            "one:payload:2"
        });
    assert(find(response, "Connection: close") < 0);
    if minor == 0 {
        assert(find(response, "Connection: keep-alive") >= 0);
    }
    body_socket::send_bytes(socket, connection_socket::request("GET", "/clean", minor, "Connection: close\r\n"));
    let second = connection_socket::receive(socket);
    connection_socket::exact(second, minor, 200, "clean");
    assert(find(second, "X-Previous:") < 0);
    connection_socket::closed(socket);
    silly_transport::close(socket);
}

fn pipeline(port: i32, minor: i32, queued: bool) {
    var socket = body_socket::connect(port);
    let keep = "Connection: keep-alive\r\n";
    let tail: u8[>..] = if queued {
        connection_socket::request("POST", "/mutate/forbidden", minor, "X-Request: first\r\n", "ignored")
    } else {
        ""
    };
    let bytes = str(connection_socket::request("GET", "/binary", minor, keep),
        connection_socket::request("GET", "/empty", minor, keep),
        connection_socket::request("HEAD", "/binary", minor, keep),
        connection_socket::request("GET", "/clean", minor, "Connection: keep-alive, ClOsE\r\n"),
        tail);
    body_socket::send_bytes(socket, bytes);
    connection_socket::exact(connection_socket::receive(socket), minor, 200, "a\x00b");
    connection_socket::exact(connection_socket::receive(socket), minor, 204, "");
    let head = connection_socket::receive(socket, true);
    connection_socket::exact(head, minor, 200, "");
    assert(find(head, "Content-Length: 3\r\n") >= 0);
    connection_socket::exact(connection_socket::receive(socket), minor, 200, "clean");
    connection_socket::closed(socket);
    silly_transport::close(socket);
}

fn bodies(port: i32) {
    var socket = body_socket::connect(port);
    let fake = connection_socket::request("POST", "/mutate/forbidden", 1, "X-Request: first\r\n", "ignored");
    body_socket::send_bytes(socket, str(connection_socket::request("POST", "/auth", 1, "", fake),
        connection_socket::request("GET", "/clean", 1, "Connection: close\r\n")));
    connection_socket::exact(connection_socket::receive(socket), 1, 401, "denied");
    connection_socket::exact(connection_socket::receive(socket), 1, 200, "clean");
    connection_socket::closed(socket);
    silly_transport::close(socket);
    socket = body_socket::connect(port);
    body_socket::send_bytes(socket, str("POST /echo HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n",
        "3\r\na\x00b\r\n0\r\nX-Trailer: safe\r\n\r\n",
        connection_socket::request("GET", "/clean", 1, "Connection: close\r\n")));
    connection_socket::exact(connection_socket::receive(socket), 1, 200, "a\x00b");
    connection_socket::exact(connection_socket::receive(socket), 1, 200, "clean");
    connection_socket::closed(socket);
    silly_transport::close(socket);
}

fn close_policy(port: i32, queued: bool) {
    var socket = body_socket::connect(port);
    body_socket::send_bytes(socket, connection_socket::request("GET", "/clean", 0));
    connection_socket::exact(connection_socket::receive(socket), 0, 200, "clean");
    connection_socket::closed(socket);
    silly_transport::close(socket);
    socket = body_socket::connect(port);
    let tail: u8[>..] = if queued {
        connection_socket::request("POST", "/mutate/forbidden", 1, "X-Request: first\r\n", "ignored")
    } else {
        ""
    };
    body_socket::send_bytes(socket, str("GET /clean HTTP/1.1\r\nHost: localhost\r\n",
        "Connection: keep-alive\r\nConnection: close\r\n\r\n", tail));
    connection_socket::exact(connection_socket::receive(socket), 1, 200, "clean");
    connection_socket::closed(socket);
    silly_transport::close(socket);
}

fn early_errors(port: i32) {
    for minor in[0, 1] {
        var socket = body_socket::connect(port);
        body_socket::send_bytes(socket, str("GET /clean HTTP/1.", minor, "\r\nHost: localhost\r\n",
            "Content-Length: 1\r\nContent-Length: 2\r\n\r\n"));
        connection_socket::exact(connection_socket::receive(socket), minor as i32, 400, "head rejected");
        connection_socket::closed(socket);
        silly_transport::close(socket);
    }
    var malformed = body_socket::connect(port);
    body_socket::send_bytes(malformed,
        "POST /echo HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\nz\r\n");
    connection_socket::exact(connection_socket::receive(malformed), 1, 400, "body rejected");
    connection_socket::closed(malformed);
    silly_transport::close(malformed);
    var socket = body_socket::connect(port);
    // Method admission must not consume unread body as a pipelined mutation.
    body_socket::send_bytes(socket, str("POST /policy/item HTTP/1.1\r\nHost: localhost\r\n",
        "Content-Length: 999\r\nExpect: 100-continue\r\n\r\n"));
    connection_socket::exact(connection_socket::receive(socket), 1, 405, "");
    connection_socket::closed(socket);
    silly_transport::close(socket);
}

fn ordered_mutations(port: i32) {
    var socket = body_socket::connect(port);
    body_socket::send_bytes(socket, str(
        connection_socket::request("POST", "/mutate/a", 1, "X-Request: first\r\n", "A"),
        connection_socket::request("POST", "/mutate/b", 1, "X-Request: first\r\nConnection: close\r\n", "B")));
    connection_socket::exact(connection_socket::receive(socket), 1, 201, "a:A:3");
    connection_socket::exact(connection_socket::receive(socket), 1, 201, "b:B:4");
    connection_socket::closed(socket);
    silly_transport::close(socket);
}

fn run(budget: i64) {
    qlimit<Stopped>(1);
    var listener = silly_transport::listen("127.0.0.1", 0, 8);
    assert(listener.status == silly_transport::IoStatus.Ready);
    let port = silly_transport::local_port(listener.descriptor);
    assert(port.status == silly_transport::IoStatus.Ready);
    var wake = silly_transport::wake_pair();
    assert(wake.status == silly_transport::IoStatus.Ready);
    let worker = thread_spawn(serve, listener.descriptor.fd, wake.reader.fd, budget);
    listener.descriptor.fd = -1;
    wake.reader.fd = -1;
    sequential(port.count as i32, 0);
    sequential(port.count as i32, 1);
    pipeline(port.count as i32, 0, budget > 7);
    pipeline(port.count as i32, 1, budget > 7);
    bodies(port.count as i32);
    close_policy(port.count as i32, budget > 7);
    early_errors(port.count as i32);
    ordered_mutations(port.count as i32);
    assert(silly_transport::notify(wake.writer).status == silly_transport::IoStatus.Ready);
    let stopped, present = qget<Stopped>(body_socket::DEADLINE_MS);
    assert(present);
    assert(stopped.ok);
    assert(stopped.app.calls == stopped.app.cleanups);
    assert(stopped.app.mutations == 4);
    assert(!stopped.app.active);
    assert(thread_wait(worker));
    silly_transport::close(wake.writer);
}

fn::main() {
    http_connection_test::run(7);
    http_connection_test::run(4096);
    print("persistent HTTP/1.0 and HTTP/1.1 sockets passed");
}
