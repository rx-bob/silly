// Real response envelopes and precommit error rendering over deliberately short writes.
namespace http_response_server_test;

import silly from "../../";

import std;

import.body_socket_fixture;

type Context = silly::Context<silly::NoState, silly::NoStream>;
var rendered: i64 = 0;

enum Route {
    Binary,
    NoContent,
    NotModified,
    Reset,
    Custom,
    Redirect,
    Missing,
    Failed,
    InvalidFields,
    Oversized,
    RendererFails,
}
struct Stopped {
    ok: bool,
    rendered: i64,
}

fn define(router: silly::Router<Route>&) {
    router.get("/binary", Route.Binary);
    router.head("/binary", Route.Binary);
    router.get("/204", Route.NoContent);
    router.get("/304", Route.NotModified);
    router.get("/205", Route.Reset);
    router.get("/custom", Route.Custom);
    router.get("/redirect", Route.Redirect);
    router.get("/missing", Route.Missing);
    router.head("/missing", Route.Missing);
    router.get("/failed", Route.Failed);
    router.get("/invalid", Route.InvalidFields);
    router.get("/oversized", Route.Oversized);
    router.get("/renderer-fails", Route.RendererFails);
}

fn plain(response: silly::Response&, status: i32, body: u8[:]) {
    assert(silly::begin_response(response, status) == silly::ResponseError.None);
    assert(silly::append_body(response, body) == silly::ResponseError.None);
}

fn handle(ctx: Context&, route: Route) {
    match route {
        Binary => {
            plain(ctx.response, 200, "a\x00b");
            assert(silly::add_header(ctx.response, "Set-Cookie", "a=1") == silly::ResponseError.None);
            assert(silly::add_header(ctx.response, "Set-Cookie", "b=2") == silly::ResponseError.None);
        },
        NoContent => {
            plain(ctx.response, 204, "");
        },
        NotModified => {
            plain(ctx.response, 304, "");
        },
        Reset => {
            plain(ctx.response, 205, "");
        },
        Custom => {
            plain(ctx.response, 299, "custom");
        },
        Redirect => {
            plain(ctx.response, 302, "");
            assert(silly::add_header(ctx.response, "Location", "/moved") == silly::ResponseError.None);
        },
        Missing => {
            return;
        },
        Failed => {
            plain(ctx.response, 200, "partial");
            let oversized: u8[128] = ['x'; 128];
            assert(silly::append_body(ctx.response, oversized) == silly::ResponseError.OutputLimit);
            return;
        },
        InvalidFields => {
            plain(ctx.response, 200, "must not leak");
            assert(silly::add_header(ctx.response, "Content-Length", "1") == silly::ResponseError.None);
        },
        Oversized => {
            plain(ctx.response, 200, "must not leak");
            let oversized: u8[400] = ['x'; 400];
            assert(silly::add_header(ctx.response, "X-Large", oversized) == silly::ResponseError.None);
        },
        RendererFails => {
            let error = silly::fail_response(ctx.response, silly::ResponseError.Application);
            assert(error == silly::ResponseError.Application);
            return;
        },
    }
    assert(silly::prepare_response(ctx.response) == silly::ResponseError.None);
}

fn render(response: silly::Response&, failure: silly::ResponseFailure) {
    rendered += 1;
    assert(response.phase == silly::ResponsePhase.Empty);
    assert(response.output.len == 0);
    assert(response.header_fields.len == 0);
    assert(response.header_bytes.len == 0);
    if failure.kind == silly::ResponseFailureKind.Admission {
        assert(failure.status == 404);
        plain(response, 404, "");
        assert(silly::prepare_response(response) == silly::ResponseError.None);
        return;
    }
    assert(failure.status == 500);
    if failure.kind == silly::ResponseFailureKind.MissingResponse {
        assert(failure.error == silly::ResponseError.MissingResponse);
        plain(response, 500, "{\"error\":\"missing\"}");
        assert(silly::add_header(response, "Content-Type", "application/json") == silly::ResponseError.None);
    } else if failure.error == silly::ResponseError.OutputLimit {
        assert(failure.kind == silly::ResponseFailureKind.HandlerFailure);
        plain(response, 507, "body limit");
    } else if failure.error == silly::ResponseError.InvalidHeader {
        assert(failure.kind == silly::ResponseFailureKind.Serialization);
        plain(response, 502, "bad metadata");
    } else if failure.error == silly::ResponseError.HeaderBytesLimit {
        assert(failure.kind == silly::ResponseFailureKind.Serialization);
        plain(response, 500, "must not leak");
        let oversized: u8[400] = ['r'; 400];
        assert(silly::add_header(response, "X-Render-Large", oversized) == silly::ResponseError.None);
    } else {
        assert(failure.error == silly::ResponseError.Application);
        return;
    }
    assert(silly::prepare_response(response) == silly::ResponseError.None);
}

thread_fn serve(listener: i32, wake: i32, custom: bool) {
    rendered = 0;
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
    let socket = silly_transport::Descriptor {
        fd: listener
    };
    let signal = silly_transport::Descriptor {
        fd: wake
    };
    let result = if custom {
        silly::run_prepared_server_with_errors(options, socket, signal, plan, handle, render)
    } else {
        silly::run_prepared_server(options, socket, signal, plan, handle)
    };
    assert(qput(Stopped {
            ok: result.ok,
            rendered: rendered
        }));
}

fn request(port: i32, method: u8[:], path: u8[:], minor: i32 = 1) -> u8[>..] {
    var socket = body_socket::connect(port);
    body_socket::send_bytes(socket, str(method, " ", path, " HTTP/1.", minor,
        "\r\nHost: localhost\r\nConnection: close\r\n\r\n"));
    let response = body_socket::receive_closed(socket);
    silly_transport::close(socket);
    return response;
}

fn exact(response: u8[:], minor: i32, status: i32, body: u8[:]) {
    assert(starts_with(response, str("HTTP/1.", minor, " ", status, " ")));
    let end = find(response, "\r\n\r\n");
    assert(end >= 0);
    assert(response[end + 4..] == body);
    assert(find(response, "must not leak") < 0);
}

fn ordinary(port: i32) {
    exact(request(port, "GET", "/unmatched", 0), 0, 404, "");
    let binary = request(port, "GET", "/binary");
    exact(binary, 1, 200, "a\x00b");
    assert(find(binary, "Content-Type:") < 0);
    assert(find(binary, "Set-Cookie: a=1\r\nSet-Cookie: b=2\r\n") >= 0);
    let head = request(port, "HEAD", "/binary");
    exact(head, 1, 200, "");
    assert(find(head, "Content-Length: 3\r\n") >= 0);
    for status in[204, 304] {
        let response = request(port, "GET", str("/", status));
        exact(response, 1, status as i32, "");
        assert(find(response, "Content-Length:") < 0);
        assert(find(response, "Transfer-Encoding:") < 0);
    }
    let reset = request(port, "GET", "/205");
    exact(reset, 1, 205, "");
    assert(find(reset, "Content-Length: 0\r\n") >= 0);
    exact(request(port, "GET", "/custom"), 1, 299, "custom");
    let redirect = request(port, "GET", "/redirect");
    exact(redirect, 1, 302, "");
    assert(find(redirect, "Location: /moved\r\n") >= 0);
}

fn custom_failures(port: i32) {
    let missing = request(port, "GET", "/missing");
    exact(missing, 1, 500, "{\"error\":\"missing\"}");
    assert(find(missing, "Content-Type: application/json\r\n") >= 0);
    let head = request(port, "HEAD", "/missing");
    exact(head, 1, 500, "");
    assert(find(head, "Content-Length: 19\r\n") >= 0);
    exact(request(port, "GET", "/missing", 0), 0, 500, "{\"error\":\"missing\"}");
    let failed = request(port, "GET", "/failed");
    exact(failed, 1, 507, "body limit");
    assert(find(failed, "Content-Type:") < 0);
    exact(request(port, "GET", "/invalid"), 1, 502, "bad metadata");
    exact(request(port, "GET", "/oversized"), 1, 500, "");
    exact(request(port, "GET", "/renderer-fails", 0), 0, 500, "");
}

fn run(custom: bool) {
    qlimit<Stopped>(1);
    var listener = silly_transport::listen("127.0.0.1", 0, 8);
    assert(listener.status == silly_transport::IoStatus.Ready);
    let port = silly_transport::local_port(listener.descriptor);
    assert(port.status == silly_transport::IoStatus.Ready);
    var wake = silly_transport::wake_pair();
    assert(wake.status == silly_transport::IoStatus.Ready);
    let worker = thread_spawn(serve, listener.descriptor.fd, wake.reader.fd, custom);
    listener.descriptor.fd = -1;
    wake.reader.fd = -1;
    if custom {
        ordinary(port.count as i32);
        custom_failures(port.count as i32);
    } else {
        exact(request(port.count as i32, "GET", "/missing"), 1, 500, "");
        exact(request(port.count as i32, "GET", "/invalid"), 1, 500, "");
    }
    assert(silly_transport::notify(wake.writer).status == silly_transport::IoStatus.Ready);
    let stopped, present = qget<Stopped>(body_socket::DEADLINE_MS);
    assert(present);
    assert(stopped.ok);
    if custom {
        assert(stopped.rendered == 8);
    } else {
        assert(stopped.rendered == 0);
    }
    assert(thread_wait(worker));
    silly_transport::close(wake.writer);
}

fn::main() {
    http_response_server_test::run(true);
    http_response_server_test::run(false);
    print("response serialization and error rendering sockets passed");
}
