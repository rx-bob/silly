// Typed application state and endpoint guards run through real bounded HTTP dispatch.
namespace endpoint_server_test;

import silly from "..";

import std;

import.body_socket_fixture;

struct App {
    requests: i64 = 0,
    cleanups: i64 = 0,
    prepared: i64 = 0,
    failed: i64 = 0,
    continued: i64 = 0,
    active: bool = false,
}
type Context = silly::Context<App, silly::NoStream>;
enum Route {
    Guarded,
    Empty,
    Fallback,
    Capacity,
    Status
}
struct Stopped {
    ok: bool,
    app: App
}

fn define(router: silly::Router<Route>&, app: App&) {
    assert(app.requests == 0);
    router.scope("/api/:tenant") {
        group =>
        group.get("/private/:id", Route.Guarded);
        group.get("/empty", Route.Empty);
        group.get("/capacity", Route.Capacity);
        group.any("/*rest", Route.Fallback);
    };
    router.get("/status", Route.Status);
}

fn require_database(ctx: Context&) {
    if ctx.param("id").value == "database" {
        silly::reject_text(ctx, 503, "database unavailable");
    }
}

fn require_permission(ctx: Context&) {
    if ctx.param("id").value == "permission" {
        silly::reject_text(ctx, 403, "permission denied");
    }
}

fn require_session(ctx: Context&) {
    require_database(ctx);
    if ctx.param("id").value == "auth" {
        silly::reject_text(ctx, 401, "session missing");
    }
    require_permission(ctx);
}

fn guarded(ctx: Context&) {
    require_session(ctx);
    ctx.app.continued += 1;
    assert(silly::respond_text(ctx, 200, str("tenant:", ctx.param("tenant").value)) == silly::ResponseError.None);
}

fn fallback(ctx: Context&) {
    assert(ctx.param("rest").value == "unknown");
    assert(!ctx.param("id").present);
    assert(silly::begin_response(ctx.response, 404) == silly::ResponseError.None);
    assert(silly::add_header(ctx.response, "Content-Type", "application/json") == silly::ResponseError.None);
    assert(silly::append_body(ctx.response, "{\"error\":\"domain missing\"}") == silly::ResponseError.None);
    assert(silly::prepare_response(ctx.response) == silly::ResponseError.None);
    silly::reject(ctx);
    abort("custom rejection continued");
}

fn status(ctx: Context&) {
    assert(!ctx.param("tenant").present);
    assert(!ctx.param("id").present);
    assert(!ctx.param("rest").present);
    assert(silly::respond_text(ctx, 200, str(ctx.app.requests, ":", ctx.app.cleanups, ":", ctx.app.continued))
        == silly::ResponseError.None);
}

fn handle(ctx: Context&, route: Route) {
    assert(!ctx.app.active);
    assert(ctx.app.requests == ctx.app.cleanups);
    ctx.app.requests += 1;
    ctx.app.active = true;
    match route {
        Guarded => {
            guarded(ctx);
        },
        Empty => {
            assert(silly::begin_response(ctx.response, 204) == silly::ResponseError.None);
            assert(silly::prepare_response(ctx.response) == silly::ResponseError.None);
        },
        Fallback => {
            fallback(ctx);
        },
        Capacity => {
            let excessive: u8[100] = ['x'; 100];
            silly::reject_text(ctx, 403, excessive);
            abort("capacity failure continued");
        },
        Status => {
            status(ctx);
        },
    }
}

fn cleanup(app: App&, outcome: silly::HandlerOutcome) {
    assert(app.active);
    assert(app.cleanups + 1 == app.requests);
    app.cleanups += 1;
    app.active = false;
    match outcome {
        Prepared => {
            app.prepared += 1;
        },
        Failed failure => {
            assert(failure.error == silly::ResponseError.OutputLimit);
            app.failed += 1;
        },
        _ => {
            assert(false);
        },
    }
}

fn render(response: silly::Response&, failure: silly::ResponseFailure) {
    if failure.kind == silly::ResponseFailureKind.Admission {
        assert(failure.status == 404);
        silly::default_response_error(response, failure);
        return;
    }
    assert(failure.kind == silly::ResponseFailureKind.HandlerFailure);
    assert(failure.error == silly::ResponseError.OutputLimit);
    assert(response.phase == silly::ResponsePhase.Empty);
    assert(silly::begin_response(response, 507) == silly::ResponseError.None);
    assert(silly::append_body(response, "bounded failure") == silly::ResponseError.None);
    assert(silly::prepare_response(response) == silly::ResponseError.None);
}

thread_fn serve(listener: i32, wake: i32) {
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
    define(router, app);
    let plan = silly::prepare(router);
    assert(plan.issue.error == silly::RouteError.None);
    let options = silly::ServerOptions {
        port: 0,
        limits: silly::Limits {
            body_bytes_max: 0,
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
    let result = silly::run_prepared_server_with_cleanup_and_errors(options,
        silly_transport::Descriptor {
            fd: listener
        }, silly_transport::Descriptor {
            fd: wake
        },
        plan, app, handle, cleanup, render);
    assert(qput(Stopped {
            ok: result.ok,
            app: app
        }));
}

fn request(port: i32, path: u8[:]) -> u8[>..] {
    var socket = body_socket::connect(port);
    body_socket::send_bytes(socket, str("GET ", path, " HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"));
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

fn verify(port: i32) {
    exact(request(port, "/api/one/private/auth"), 401, "session missing");
    exact(request(port, "/api/two/private/permission"), 403, "permission denied");
    exact(request(port, "/api/three/private/database"), 503, "database unavailable");
    exact(request(port, "/api/a%2Fb/private/accepted"), 200, "tenant:a%2Fb");
    exact(request(port, "/api/four/empty"), 204, "");
    let fallback_response = request(port, "/api/five/unknown");
    exact(fallback_response, 404, "{\"error\":\"domain missing\"}");
    assert(find(fallback_response, "Content-Type: application/json\r\n") >= 0);
    exact(request(port, "/api/six/capacity"), 507, "bounded failure");
    exact(request(port, "/status"), 200, "8:7:1");
    exact(request(port, "/outside"), 404, "");
    exact(request(port, "/status"), 200, "9:8:1");
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
    assert(stopped.app.requests == 9);
    assert(stopped.app.cleanups == 9);
    assert(stopped.app.prepared == 8);
    assert(stopped.app.failed == 1);
    assert(stopped.app.continued == 1);
    assert(!stopped.app.active);
    assert(thread_wait(worker));
    silly_transport::close(wake.writer);
    print("typed endpoint guards and cleanup sockets passed");
}

fn::main() {
    endpoint_server_test::run();
}
