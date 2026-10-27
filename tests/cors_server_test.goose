// Real sockets preserve CORS and consumer-specific envelopes across every response path.
namespace cors_server_test;

import silly from "..";

import std;

import.body_socket_fixture;
import.connection_socket_fixture;

struct App {
    handled: i64 = 0
}
type Context = silly::Context<App, silly::NoStream>;
enum Route {
    Ok,
    Plain,
    Failed,
    Conflict,
    Body
}
struct Stopped {
    ok: bool,
    handled: i64
}
struct ErrorBody {
    error: const u8[:]
}
struct GlobalError {
    error: const u8[:],
    path: const u8[:]
}
struct AdminDetails {
    code: const u8[:],
    category: const u8[:],
    message: const u8[:],
    request_id: const u8[:],
    environment: const u8[:],
}
struct AdminError {
    error: AdminDetails
}

fn define(router: silly::Router<Route>&) {
    router.error_policy(1);
    router.scope("/api") {
        api =>
        api.error_policy(2);
        api.cors(silly::CorsPolicy {
                origin: "*",
                methods: "GET, POST, PUT, PATCH, DELETE, OPTIONS",
                headers: "Content-Type, Authorization",
                preflight_status: 200,
                options_without_origin: true,
                ..
            });
        api.policy = silly::RoutePolicy {
            method_not_allowed: true,
            ..
        };
        api.get("/ok", Route.Ok);
        api.get("/plain", Route.Plain);
        api.get("/failed", Route.Failed);
        api.get("/conflict", Route.Conflict);
        api.post("/body", Route.Body, silly::RouteOptions {
                body_bytes_max: 3,
                ..
            });
        api.scope("/portal") {
            portal =>
            portal.error_policy(4);
            portal.cors(silly::CorsPolicy {
                });
            portal.get("/ok", Route.Ok);
        };
    };
    router.scope("/admin") {
        admin =>
        admin.error_policy(3);
        admin.cors(silly::CorsPolicy {
                origins: "https://admin.example, https://other.example",
                methods: "GET, POST",
                headers: "Authorization",
                expose_headers: "X-Request-Id",
                credentials: true,
                max_age_seconds: 60,
                ..
            });
        admin.get("/ok", Route.Ok);
    };
    router.scope("/portal") {
        portal =>
        portal.error_policy(4);
        portal.cors(silly::CorsPolicy {
            });
        portal.get("/ok", Route.Ok);
    };
}

fn handle(ctx: Context&, route: Route) {
    ctx.app.handled += 1;
    match route {
        Ok => {
            ctx.text(200, "ok");
        },
        Plain => {
            ctx.bytes(401, "Missing token or session", silly::BodyOptions {
                });
            ctx.reject();
        },
        Failed => {
            silly::audit_request_id(ctx, "cors-error-id");
            ctx.text(200, "must not leak");
            silly::fail_response(ctx.response, silly::ResponseError.Application);
        },
        Conflict => {
            ctx.text(200, "ok");
            silly::add_header(ctx.response, "Access-Control-Allow-Origin", "https://evil.example");
            silly::add_header(ctx.response, "access-control-allow-origin", "https://second.example");
            silly::add_header(ctx.response, "Access-Control-Allow-Credentials", "true");
            silly::add_header(ctx.response, "Access-Control-Expose-Headers", "X-Secret");
            silly::add_header(ctx.response, "Vary", "Accept-Encoding");
            silly::add_header(ctx.response, "Vary", "accept-encoding, Origin");
        },
        Body => {
            ctx.text(200, ctx.body());
        },
    }
}

fn message(status: i32) -> const u8[:] {
    return if status == 404 {
        "Not found"
    } else if status == 405 {
        "Method not allowed"
    } else if status == 413 {
        "Body too large"
    } else if status == 403 {
        "Forbidden"
    } else if status == 500 {
        "Application failed"
    } else {
        "Bad request"
    };
}

fn json_error<T>(response: silly::Response&, status: i32, model: T&) {
    assert(silly::begin_response(response, status) == silly::ResponseError.None);
    assert(silly::add_header(response, "Content-Type", "application/json") == silly::ResponseError.None);
    var writer = silly::JsonWriter {
        output: response.output,
        cap: response.limits.output_bytes_max,
        ..
    };
    assert(silly::write_json(writer, model) == silly::JsonError.None);
    assert(silly::prepare_response(response) == silly::ResponseError.None);
}

fn render(response: silly::Response&, failure: silly::ResponseFailure) {
    if failure.error_policy == 2 && failure.status == 500 {
        assert(failure.audit.request_id == "cors-error-id");
    }
    if failure.error_policy == 0 || failure.error_policy == 4 {
        assert(silly::begin_response(response, failure.status) == silly::ResponseError.None);
        let text = if failure.error_policy == 0 {
            "parse error"
        } else {
            "portal missing"
        };
        assert(silly::append_body(response, text) == silly::ResponseError.None);
        assert(silly::prepare_response(response) == silly::ResponseError.None);
    } else if failure.error_policy == 1 {
        let model = GlobalError {
            error: message(failure.status),
            path: failure.target
        };
        json_error(response, failure.status, model);
    } else if failure.error_policy == 2 {
        let model = ErrorBody {
            error: message(failure.status)
        };
        json_error(response, failure.status, model);
    } else {
        assert(failure.error_policy == 3);
        let detail = str(if failure.status == 404 {
                "Admin route not found for "
            } else {
                "Admin request rejected for "
            },
            failure.target);
        let model = AdminError {
            error: AdminDetails {
                code: if failure.status == 404 {
                    "not_found"
                } else {
                    "request_rejected"
                },
                category: if failure.status == 404 {
                    "data_absence"
                } else {
                    "policy"
                },
                message: detail,
                request_id: "rid-fixture",
                environment: "test"
            }
        };
        json_error(response, failure.status, model);
    }
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
    define(router);
    let plan = silly::prepare(router);
    assert(plan.issue.error == silly::RouteError.None);
    let options = silly::ServerOptions {
        limits: silly::Limits {
            body_bytes_max: 32,
            output_bytes_max: 1024,
            ..
        },
        connections_max: 2,
        response_head_bytes_max: 2048,
        buffer_bytes_max: 128 * 1024,
        work_bytes_per_turn: 7,
        accepts_per_turn: 2,
        poll_timeout_ms: 10,
        ..
    };
    let result = silly::run_prepared_server_with_errors(options,
        silly_transport::Descriptor {
            fd: listener
        }, silly_transport::Descriptor {
            fd: wake
        },
        plan, app, handle, render);
    assert(qput(Stopped {
            ok: result.ok,
            handled: app.handled
        }));
}

fn raw(port: i32, input: u8[:]) -> u8[>..] {
    var socket = body_socket::connect(port);
    body_socket::send_bytes(socket, input);
    let response = body_socket::receive_closed(socket);
    silly_transport::close(socket);
    return response;
}

fn request(port: i32, method: u8[:], path: u8[:], fields: u8[:] = "", body: u8[:] = "") -> u8[>..] {
    return raw(port, connection_socket::request(method, path, 1, str("Connection: close\r\n", fields), body));
}

fn header_count(response: u8[:], name: u8[:]) -> i64 {
    var count: i64 = 0;
    var start = find(response, "\r\n") + 2;
    let end = find(response, "\r\n\r\n");
    assert(start >= 2);
    assert(end >= start - 2);
    while start < end {
        let width = find(response[start..], "\r\n");
        assert(width >= 0);
        let line = response[start..start + width];
        let colon = find(line, ":");
        assert(colon > 0);
        if silly::header_name_equal(line[..colon], name) {
            count += 1;
        }
        start += width + 2;
    }
    return count;
}

fn wildcard(response: u8[:]) {
    assert(find(response, "Access-Control-Allow-Origin: *\r\n") >= 0);
    assert(header_count(response, "Access-Control-Allow-Origin") == 1);
    assert(header_count(response, "Access-Control-Allow-Credentials") == 0);
}

fn responses(port: i32) {
    let ok = request(port, "GET", "/api/ok", "Origin: https://client.example\r\n");
    connection_socket::exact(ok, 1, 200, "ok");
    wildcard(ok);
    let plain = request(port, "GET", "/api/plain");
    connection_socket::exact(plain, 1, 401, "Missing token or session");
    assert(header_count(plain, "Content-Type") == 0);
    wildcard(plain);
    let failed = request(port, "GET", "/api/failed");
    connection_socket::exact(failed, 1, 500, "{\"error\":\"Application failed\"}");
    assert(find(failed, "must not leak") < 0);
    wildcard(failed);
    let conflict = request(port, "GET", "/api/conflict");
    connection_socket::exact(conflict, 1, 200, "ok");
    wildcard(conflict);
    assert(find(conflict, "evil.example") < 0);
    assert(find(conflict, "second.example") < 0);
    assert(find(conflict, "X-Secret") < 0);
    assert(find(conflict, "Accept-Encoding") >= 0);
    assert(header_count(conflict, "Vary") == 1);
}

fn preflight(port: i32) {
    for method in["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"] {
        let response = request(port, "OPTIONS", "/api/unknown", str("Origin: https://client.example\r\n",
            "Access-Control-Request-Method: ", method, "\r\n",
            "Access-Control-Request-Headers: content-type, AUTHORIZATION\r\n"));
        connection_socket::exact(response, 1, 200, "");
        wildcard(response);
        assert(find(response, "Access-Control-Allow-Methods: GET, POST, PUT, PATCH, DELETE, OPTIONS\r\n") >= 0);
        assert(find(response, "Access-Control-Allow-Headers: Content-Type, Authorization\r\n") >= 0);
    }
    connection_socket::exact(request(port, "OPTIONS", "/api/unknown"), 1, 200, "");
    let denied = request(port, "OPTIONS", "/api/ok", str("Origin: https://client.example\r\n",
        "Access-Control-Request-Method: POST\r\nAccess-Control-Request-Headers: X-Forbidden\r\n"));
    connection_socket::exact(denied, 1, 403, "{\"error\":\"Forbidden\"}");
    let early = raw(port, str("OPTIONS /api/ok HTTP/1.1\r\nHost: x\r\nOrigin: https://client.example\r\n",
        "Access-Control-Request-Method: DELETE\r\nContent-Length: 999\r\nExpect: 100-continue\r\n\r\n"));
    connection_socket::exact(early, 1, 200, "");
    assert(find(early, "100 Continue") < 0);
}

fn credentialed(port: i32) {
    let ok = request(port, "GET", "/admin/ok", "Origin: https://admin.example\r\n");
    connection_socket::exact(ok, 1, 200, "ok");
    assert(find(ok, "Access-Control-Allow-Origin: https://admin.example\r\n") >= 0);
    assert(find(ok, "Access-Control-Allow-Credentials: true\r\n") >= 0);
    assert(find(ok, "Access-Control-Expose-Headers: X-Request-Id\r\n") >= 0);
    assert(find(ok, "Vary: Origin\r\n") >= 0);
    let absent = request(port, "GET", "/admin/ok");
    connection_socket::exact(absent, 1, 200, "ok");
    assert(header_count(absent, "Access-Control-Allow-Origin") == 0);
    assert(find(absent, "Vary: Origin\r\n") >= 0);
    let denied = request(port, "GET", "/admin/ok", "Origin: https://evil.example\r\n");
    assert(starts_with(denied, "HTTP/1.1 403 "));
    assert(header_count(denied, "Access-Control-Allow-Origin") == 0);
    assert(find(denied, "Vary: Origin\r\n") >= 0);
    let pre = request(port, "OPTIONS", "/admin/ok", str("Origin: https://other.example\r\n",
        "Access-Control-Request-Method: POST\r\nAccess-Control-Request-Headers: authorization\r\n"));
    connection_socket::exact(pre, 1, 204, "");
    assert(find(pre, "Access-Control-Allow-Origin: https://other.example\r\n") >= 0);
    assert(find(pre, "Access-Control-Max-Age: 60\r\n") >= 0);
}

fn scopes(port: i32) {
    let api = request(port, "GET", "/api/missing");
    connection_socket::exact(api, 1, 404, "{\"error\":\"Not found\"}");
    wildcard(api);
    let global = request(port, "GET", "/apiculture");
    connection_socket::exact(global, 1, 404, "{\"error\":\"Not found\",\"path\":\"/apiculture\"}");
    assert(header_count(global, "Access-Control-Allow-Origin") == 0);
    let admin = request(port, "GET", "/admin/missing", "Origin: https://admin.example\r\n");
    assert(starts_with(admin, "HTTP/1.1 404 "));
    assert(find(admin, "\"code\":\"not_found\",\"category\":\"data_absence\"") >= 0);
    assert(find(admin, "Admin route not found for /admin/missing") >= 0);
    assert(find(admin, "\"request_id\":\"rid-fixture\",\"environment\":\"test\"") >= 0);
    assert(find(admin, "Access-Control-Allow-Origin: https://admin.example\r\n") >= 0);
    let portal = request(port, "GET", "/api/portal/missing");
    connection_socket::exact(portal, 1, 404, "portal missing");
    assert(header_count(portal, "Content-Type") == 0);
    assert(header_count(portal, "Access-Control-Allow-Origin") == 0);
    let method = request(port, "PUT", "/api/ok");
    connection_socket::exact(method, 1, 405, "{\"error\":\"Method not allowed\"}");
    assert(find(method, "Allow: GET\r\n") >= 0);
    wildcard(method);
}

fn bad_input(port: i32) {
    let malformed = raw(port, "GET /api/missing HTTP/1.1\r\nHost: a\r\nHost: b\r\nOrigin: https://x.example\r\n\r\n");
    connection_socket::exact(malformed, 1, 400, "parse error");
    assert(header_count(malformed, "Access-Control-Allow-Origin") == 0);
    let limited = raw(port, str("POST /api/body HTTP/1.1\r\nHost: x\r\nContent-Length: 4\r\n",
        "Expect: 100-continue\r\n\r\n"));
    connection_socket::exact(limited, 1, 413, "{\"error\":\"Body too large\"}");
    assert(find(limited, "100 Continue") < 0);
    wildcard(limited);
    let chunked = raw(port, "POST /api/body HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\nz\r\n");
    connection_socket::exact(chunked, 1, 400, "{\"error\":\"Bad request\"}");
    wildcard(chunked);
    connection_socket::exact(request(port, "POST", "/api/body", "", "abc"), 1, 200, "abc");
}

fn persistent(port: i32) {
    var socket = body_socket::connect(port);
    body_socket::send_bytes(socket, connection_socket::request("OPTIONS", "/api/ok", 1,
        "Origin: https://client.example\r\nAccess-Control-Request-Method: GET\r\n"));
    let preflight = connection_socket::receive(socket);
    connection_socket::exact(preflight, 1, 200, "");
    wildcard(preflight);
    for path in["/api/ok", "/api/portal/ok", "/admin/ok"] {
        let fields = if path == "/admin/ok" {
            "Connection: close\r\nOrigin: https://admin.example\r\n"
        } else {
            ""
        };
        body_socket::send_bytes(socket, connection_socket::request("GET", path, 1, fields));
        let response = connection_socket::receive(socket);
        connection_socket::exact(response, 1, 200, "ok");
        if path == "/api/ok" {
            wildcard(response);
        } else if path == "/api/portal/ok" {
            assert(header_count(response, "Access-Control-Allow-Origin") == 0);
        } else {
            assert(find(response, "Access-Control-Allow-Origin: https://admin.example\r\n") >= 0);
        }
    }
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
    let number = port.count as i32;
    responses(number);
    preflight(number);
    credentialed(number);
    scopes(number);
    bad_input(number);
    persistent(number);
    assert(silly_transport::notify(wake.writer).status == silly_transport::IoStatus.Ready);
    let stopped, present = qget<Stopped>(1000);
    assert(present);
    assert(stopped.ok);
    assert(stopped.handled == 10);
    assert(thread_wait(worker));
    silly_transport::close(wake.writer);
}

fn::main() {
    cors_server_test::run();
    print("CORS preflight, scoped errors and response policy sockets passed");
}
