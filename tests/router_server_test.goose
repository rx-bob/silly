// Scoped method policy shares admission, dispatch, capture views and wire semantics.
namespace router_server_test;

import silly from "..";

import std;

import.body_socket_fixture;

type Context = silly::Context<silly::NoState, silly::NoStream>;
enum Route {
    Capture,
    ExplicitHead,
    ExplicitOptions,
    Fallback,
    Body
}
struct Stopped {
    ok: bool
}

fn define(router: silly::Router<Route>&) {
    router.scope("/api") {
        group =>
        group.policy = silly::RoutePolicy {
            head_from_get: true,
            automatic_options: true,
            method_not_allowed: true,
        };
        group.get("/users/:email", Route.Capture);
        group.patch("/users/:email", Route.Body);
        group.get("/explicit", Route.Capture);
        group.head("/explicit", Route.ExplicitHead);
        group.options("/explicit", Route.ExplicitOptions);
    };
    router.get("/plain", Route.Capture);
    router.scope("/custom") {
        group =>
        group.get("/known", Route.Capture);
        group.any("/*rest", Route.Fallback);
    };
}

fn handle(ctx: Context&, route: Route) {
    let status: i32 = if route == Route.Fallback {
        404
    } else {
        200
    };
    assert(silly::begin_response(ctx.response, status) == silly::ResponseError.None);
    match route {
        Capture => {
            let email = silly::param(ctx, "email");
            assert(silly::append_body(ctx.response, if email.present {
                    email.value
                } else {
                    "get"
                })
                == silly::ResponseError.None);
        },
        ExplicitHead => {
            assert(ctx.request.method == "HEAD");
            assert(silly::add_header(ctx.response, "X-Explicit", "head") == silly::ResponseError.None);
            assert(silly::append_body(ctx.response, "explicit") == silly::ResponseError.None);
        },
        ExplicitOptions => {
            assert(silly::append_body(ctx.response, "options") == silly::ResponseError.None);
        },
        Fallback => {
            assert(silly::append_body(ctx.response, "{\"error\":\"missing\"}") == silly::ResponseError.None);
        },
        Body => {
            assert(ctx.request.method == "PATCH");
            match silly::body_view(ctx) {
                Available body => {
                    assert(silly::append_body(ctx.response, body.bytes) == silly::ResponseError.None);
                },
                _ => {
                    assert(false);
                },
            }
        },
    }
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
            body_bytes_max: 32,
            output_bytes_max: 64,
            ..
        },
        connections_max: 2,
        response_head_bytes_max: 256,
        buffer_bytes_max: 128 * 1024,
        work_bytes_per_turn: 3,
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
        }, plan, handle);
    assert(qput(Stopped {
            ok: result.ok
        }));
}

fn request(port: i32, method: u8[:], path: u8[:], body: u8[:] = "") -> u8[>..] {
    var socket = body_socket::connect(port);
    body_socket::send_bytes(socket, str(method, " ", path,
        " HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\nContent-Length: ", body.len, "\r\n\r\n", body));
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

fn early_methods(port: i32) {
    for method in["PUT", "OPTIONS"] {
        var socket = body_socket::connect(port);
        body_socket::send_bytes(socket, str(method, " /api/users/x HTTP/1.1\r\n",
            "Host: localhost\r\nConnection: close\r\nContent-Length: 999999\r\nExpect: 100-continue\r\n\r\n"));
        let response = body_socket::receive_closed(socket);
        exact(response, if method == "PUT" {
                405
            } else {
                204
            }, "");
        assert(find(response, "100 Continue") < 0);
        assert(find(response, "Allow: GET, HEAD, OPTIONS, PATCH\r\n") >= 0);
        silly_transport::close(socket);
    }
}

fn verify(port: i32) {
    let path = "/api/users/a+b%252F@example.test";
    exact(request(port, "GET", path), 200, "a+b%252F@example.test");
    let head = request(port, "HEAD", path);
    exact(head, 200, "");
    assert(find(head, "Content-Length: 21\r\n") >= 0);
    for method in["PUT", "OPTIONS"] {
        let response = request(port, method, path);
        exact(response, if method == "PUT" {
                405
            } else {
                204
            }, "");
        assert(find(response, "Allow: GET, HEAD, OPTIONS, PATCH\r\n") >= 0);
    }
    exact(request(port, "PATCH", path, "payload"), 200, "payload");
    exact(request(port, "GET", str(path, "/extra")), 404, "");
    let explicit_head = request(port, "HEAD", "/api/explicit");
    exact(explicit_head, 200, "");
    assert(find(explicit_head, "X-Explicit: head\r\n") >= 0);
    assert(find(explicit_head, "Content-Length: 8\r\n") >= 0);
    exact(request(port, "OPTIONS", "/api/explicit"), 200, "options");
    exact(request(port, "HEAD", "/plain"), 404, "");
    exact(request(port, "OPTIONS", "/plain"), 404, "");
    exact(request(port, "DELETE", "/custom/known"), 404, "{\"error\":\"missing\"}");
    exact(request(port, "GET", "/custom/unknown"), 404, "{\"error\":\"missing\"}");
    exact(request(port, "OPTIONS", "/outside"), 404, "");
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
    early_methods(port.count as i32);
    assert(silly_transport::notify(wake.writer).status == silly_transport::IoStatus.Ready);
    let stopped, present = qget<Stopped>(body_socket::DEADLINE_MS);
    assert(present);
    assert(stopped.ok);
    assert(thread_wait(worker));
    silly_transport::close(wake.writer);
    print("scoped route method socket tests passed");
}

fn::main() {
    router_server_test::run();
}
