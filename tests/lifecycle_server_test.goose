// Lifecycle events retain owned audit data through delivery, reset and cancellation.
namespace lifecycle_server_test;

import silly from "..";

import std;

import.body_socket_fixture;
import.connection_socket_fixture;

extern fn silly_lifecycle_reset_close(fd: i32) -> i32;

struct App {
    mode: i32 = 0,
    starts: i64 = 0,
    handlers: i64 = 0,
    transfers: i64 = 0,
    stops: i64 = 0,
    log: u8[..512] = [],
}
type Context = silly::Context<App, silly::NoStream>;
enum Route {
    Normal,
    Mcp,
    Admin,
    Missing,
    Failed,
    Large
}
struct Record {
    kind: i32,
    data: silly::CompletionData = silly::CompletionData {
    }
}
struct Stopped {
    ok: bool,
    hook_failed: bool,
    app: App
}
struct AdminError {
    request_id: const u8[:],
    error: const u8[:]
}
const ALIASES = [silly::JsonAlias {
        field: "request_id",
        wire: "requestId"
    }];

fn define(router: silly::Router<Route>&) {
    router.scope("/api") {
        group =>
        group.post("/normal", Route.Normal);
        group.get("/mcp", Route.Mcp);
        group.get("/admin", Route.Admin);
        group.get("/missing", Route.Missing);
        group.get("/failed", Route.Failed);
        group.get("/large", Route.Large);
    };
}

fn global_before(ctx: Context&, route: Route) {
    ctx.app.log.append("G");
    let id = ctx.header("X-Request-ID");
    silly::audit_request_id(ctx, if id.present {
            id.value
        } else {
            "none"
        });
    silly::audit_data(ctx, "audit selected");
}

fn group_before(ctx: Context&, route: Route) {
    ctx.app.log.append("M");
}

fn route_before(ctx: Context&, route: Route) {
    ctx.app.log.append("R");
    if route == Route.Mcp {
        ctx.bytes(401, "Missing token or session");
        silly::audit_response_payload(ctx, 256);
        ctx.reject();
    }
    if route == Route.Admin {
        let reply = AdminError {
            request_id: ctx.header("X-Request-ID").value,
            error: "forbidden"
        };
        ctx.json(403, reply, silly::JsonWriteOptions {
                aliases: ALIASES,
                ..
            });
        silly::add_header(ctx.response, "X-Request-ID", reply.request_id);
        silly::audit_response_payload(ctx, 256);
        ctx.reject();
    }
}

fn actual(ctx: Context&, route: Route) {
    ctx.app.log.append("H");
    if route == Route.Missing {
        return;
    }
    if route == Route.Failed {
        silly::fail_response(ctx.response, silly::ResponseError.Application);
        return;
    }
    if route == Route.Large {
        let large: u8[262144] = ['x'; 262144];
        ctx.bytes(200, large);
    } else {
        silly::audit_request_payload(ctx, 3);
        let id = ctx.header("X-Request-ID");
        ctx.text(200, id.value);
        silly::add_header(ctx.response, "X-Request-ID", id.value);
    }
    silly::audit_response_payload(ctx, 8);
}

fn handle(ctx: Context&, route: Route) {
    silly::middleware(ctx, route, global_before, group_before, route_before, actual);
}

fn global_after(app: App&, event: silly::Lifecycle<Route>) -> silly::HookResult {
    app.log.append("g");
    return silly::HookResult.Ok;
}

fn group_after(app: App&, event: silly::Lifecycle<Route>) -> silly::HookResult {
    app.log.append("m");
    return silly::HookResult.Ok;
}

fn route_after(app: App&, event: silly::Lifecycle<Route>) -> silly::HookResult {
    app.log.append("r");
    return silly::HookResult.Ok;
}

fn lifecycle(app: App&, event: silly::Lifecycle<Route>) -> silly::HookResult {
    let result = silly::middleware_complete(app, event, global_after, group_after, route_after);
    assert(result == silly::HookResult.Ok);
    var kind: i32 = 0;
    var data = silly::CompletionData {
    };
    match event {
        Start start => {
            assert(start.owner.id == 0);
            app.starts += 1;
            kind = 1;
        },
        HandlerFinished done => {
            check_route(done.completion);
            app.handlers += 1;
            kind = 2;
            data = done.completion.data;
        },
        TransferFinished done => {
            app.transfers += 1;
            kind = 3;
            data = done.completion.data;
        },
        Stop stop => {
            assert(stop.owner.id == 0);
            app.stops += 1;
            kind = 4;
        },
    }
    assert(qput(Record {
            kind: kind,
            data: data
        }));
    if app.mode == kind {
        return silly::HookResult.Failed {
            message: "hook failed"
        };
    }
    return silly::HookResult.Ok;
}

fn check_route(completion: silly::Completion<Route>) {
    assert(completion.data.selection == silly::CompletionSelection.Matched);
    assert(completion.data.handler_ran);
    match completion.route {
        Application selected => {
            if selected.route == Route.Mcp {
                assert(completion.data.target == "/api/mcp");
            }
            if selected.route == Route.Admin {
                assert(completion.data.target == "/api/admin");
            }
        },
        _ => {
            assert(false);
        },
    }
}

thread_fn serve(listener: i32, wake: i32, mode: i32) {
    var app = App {
        mode: mode,
        ..
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
            body_bytes_max: 1024,
            output_bytes_max: 262144,
            ..
        },
        connections_max: 2,
        response_head_bytes_max: 512,
        buffer_bytes_max: 1024 * 1024,
        work_bytes_per_turn: 7,
        accepts_per_turn: 2,
        idle_timeout_ms: 500,
        poll_timeout_ms: 10,
        ..
    };
    let result = silly::run_prepared_server_with_lifecycle(options,
        silly_transport::Descriptor {
            fd: listener
        }, silly_transport::Descriptor {
            fd: wake
        },
        plan, app, handle, lifecycle);
    assert(qput(Stopped {
            ok: result.ok,
            hook_failed: result.error == silly::ServerError.Hook,
            app: app
        }));
}

fn record(kind: i32) -> silly::CompletionData {
    let event, present = qget<Record>(10000);
    assert(present);
    assert(event.kind == kind);
    return event.data;
}

fn ordinary(port: i32) {
    for item in["normal", "mcp", "admin", "missing", "failed"] {
        var socket = body_socket::connect(port);
        body_socket::send_bytes(socket, connection_socket::request(if item == "normal" {
                "POST"
            } else {
                "GET"
            },
            str("/api/", item), 1, "Connection: close\r\nX-Request-ID: r7\r\n", if item == "normal" {
                "abcdef"
            } else {
                ""
            }));
        let response = body_socket::receive_closed(socket);
        let handled = record(2);
        let transferred = record(3);
        assert(transferred.transfer == silly::TransferOutcome.Delivered);
        assert(transferred.wire_bytes == response.len);
        assert(handled.audit.request_id == "r7");
        assert(transferred.audit.request_id == "r7");
        assert(transferred.audit.data == "audit selected");
        assert(handled.entered == 7);
        if item == "normal" {
            connection_socket::exact(response, 1, 200, "r7");
            assert(find(response, "X-Request-ID: r7\r\n") >= 0);
            assert(transferred.audit.request_payload == "abc");
            assert(transferred.audit.request_truncated);
        } else if item == "mcp" {
            connection_socket::exact(response, 1, 401, "Missing token or session");
            assert(find(response, "Content-Type:") < 0);
        } else if item == "admin" {
            connection_socket::exact(response, 1, 403, "{\"requestId\":\"r7\",\"error\":\"forbidden\"}");
            assert(find(response, "X-Request-ID: r7\r\n") >= 0);
            assert(find(response, "Content-Type: application/json\r\n") >= 0);
        } else {
            connection_socket::exact(response, 1, 500, "");
            assert(transferred.status == 500);
        }
        silly_transport::close(socket);
    }
}

fn peer_reset(port: i32) {
    var socket = body_socket::connect(port);
    assert(silly_transport::set_receive_buffer(socket, 1024).status == silly_transport::IoStatus.Ready);
    body_socket::send_bytes(socket, connection_socket::request("GET", "/api/large"));
    let handled = record(2);
    assert(handled.audit.response_payload.len == 8);
    assert(handled.audit.response_truncated);
    assert(silly_lifecycle_reset_close(socket.fd) == 0);
    silly_transport::close(socket);
    let transferred = record(3);
    assert(transferred.transfer == silly::TransferOutcome.Cancelled);
    assert(transferred.audit.response_payload.len == 8);
}

fn partial_timeout(port: i32) {
    var socket = body_socket::connect(port);
    body_socket::send_bytes(socket, "POST /api/normal HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\na");
    let response = body_socket::receive_closed(socket);
    connection_socket::exact(response, 1, 408, "");
    let transferred = record(3);
    assert(transferred.status == 408);
    assert(!transferred.handler_ran);
    assert(transferred.selection == silly::CompletionSelection.Matched);
    silly_transport::close(socket);
}

fn not_found(port: i32) {
    var socket = body_socket::connect(port);
    body_socket::send_bytes(socket, connection_socket::request("GET", "/absent"));
    connection_socket::exact(body_socket::receive_closed(socket), 1, 404, "");
    let transferred = record(3);
    assert(!transferred.handler_ran);
    assert(transferred.selection == silly::CompletionSelection.NotFound);
    assert(transferred.status == 404);
    silly_transport::close(socket);
}

fn run(mode: i32) {
    qlimit<Record>(32);
    qlimit<Stopped>(1);
    var listener = silly_transport::listen("127.0.0.1", 0, 8);
    assert(listener.status == silly_transport::IoStatus.Ready);
    let port = silly_transport::local_port(listener.descriptor);
    assert(port.status == silly_transport::IoStatus.Ready);
    var wake = silly_transport::wake_pair();
    assert(wake.status == silly_transport::IoStatus.Ready);
    let worker = thread_spawn(serve, listener.descriptor.fd, wake.reader.fd, mode);
    listener.descriptor.fd = -1;
    wake.reader.fd = -1;
    record(1);
    var pending = silly_transport::Descriptor {
    };
    if mode == 0 {
        ordinary(port.count as i32);
        peer_reset(port.count as i32);
        partial_timeout(port.count as i32);
        not_found(port.count as i32);
        pending = body_socket::connect(port.count as i32);
        assert(silly_transport::set_receive_buffer(pending, 1024).status == silly_transport::IoStatus.Ready);
        body_socket::send_bytes(pending, connection_socket::request("GET", "/api/large"));
        record(2);
    } else if mode == 2 || mode == 3 {
        pending = body_socket::connect(port.count as i32);
        body_socket::send_bytes(pending, connection_socket::request("POST", "/api/normal", 1,
            "X-Request-ID: r7\r\n", "abcdef"));
        record(2);
        let transferred = record(3);
        let expected = if mode == 2 {
            silly::TransferOutcome.Cancelled
        } else {
            silly::TransferOutcome.Delivered
        };
        assert(transferred.transfer == expected);
    }
    if mode == 0 || mode == 4 {
        assert(silly_transport::notify(wake.writer).status == silly_transport::IoStatus.Ready);
        if mode == 0 {
            assert(record(3).transfer == silly::TransferOutcome.Cancelled);
        }
    }
    record(4);
    let stopped, present = qget<Stopped>(10000);
    assert(present);
    assert(stopped.ok == (mode == 0));
    assert(stopped.hook_failed == (mode != 0));
    assert(stopped.app.starts == 1);
    assert(stopped.app.stops == 1);
    if mode == 0 {
        assert(stopped.app.handlers == 7);
        assert(stopped.app.transfers == 9);
        assert(stopped.app.log == str("GMRHrmgrmg", "GMRrmgrmg", "GMRrmgrmg",
            "GMRHrmgrmg", "GMRHrmgrmg", "GMRHrmgrmg", "GMRHrmgrmg"));
    }
    if mode == 1 {
        assert(stopped.app.handlers == 0);
        assert(stopped.app.transfers == 0);
    }
    let extra, extra_present = qpoll<Record>();
    assert(!extra_present);
    assert(thread_wait(worker));
    silly_transport::close(pending);
    silly_transport::close(wake.writer);
}

fn::main() {
    for mode in 5 {
        lifecycle_server_test::run(mode as i32);
    }
    print("lifecycle delivery, cancellation and hook failures passed");
}
