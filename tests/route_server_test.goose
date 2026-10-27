// Static route preparation occurs once; real socket dispatch uses immutable prepared entries.
namespace route_server_test;

import silly from "..";

import std;

let DEADLINE_MS = 10000;
var definitions: i64 = 0;
var handled: i64 = 0;

type Context = silly::Context<silly::NoState, silly::NoStream>;
enum Route {
    Static,
    Capture,
    Wildcard,
    Post,
}
struct Stopped {
    ok: bool,
    definitions: i64,
    handled: i64,
}

fn define(router: silly::Router<Route>&) {
    definitions += 1;
    router.get("/items/new", Route.Static);
    router.get("/items/:id", Route.Capture);
    router.get("/assets/*path", Route.Wildcard);
    router.post("/items", Route.Post);
    router.head("/items/new", Route.Static);
}

fn invalid(router: silly::Router<Route>&) {
    definitions += 1;
    router.get("/same", Route.Static);
    router.get("/same", Route.Capture);
}

fn handle(ctx: Context&, route: Route) {
    handled += 1;
    let text = match route {
        Static => {
            "static"
        },
        Capture => {
            "capture"
        },
        Wildcard => {
            "wildcard"
        },
        Post => {
            "post"
        },
    };
    assert(silly::begin_response(ctx.response, 200) == silly::ResponseError.None);
    assert(silly::append_body(ctx.response, text) == silly::ResponseError.None);
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
            body_bytes_max: 0,
            output_bytes_max: 32,
            ..
        },
        connections_max: 4,
        response_head_bytes_max: 256,
        buffer_bytes_max: 256 * 1024,
        work_bytes_per_turn: 7,
        accepts_per_turn: 4,
        poll_timeout_ms: 10,
        ..
    };
    let result = silly::run_prepared_server(options,
        silly_transport::Descriptor {
            fd: listener
        }, silly_transport::Descriptor {
            fd: wake
        }, plan, handle);
    assert(qput(Stopped {
            ok: result.ok,
            definitions: definitions,
            handled: handled
        }));
}

fn now() -> i64 {
    let result = silly_transport::monotonic_ms();
    assert(result.status == silly_transport::IoStatus.Ready);
    return result.count;
}

fn ready(socket: silly_transport::Descriptor, interest: i32, deadline: i64) {
    let fds: i32[1] = [socket.fd];
    let interests: i32[1] = [interest];
    var events: i32[1] = [0];
    while now() < deadline {
        let result = silly_transport::poll(fds, interests, events, 10);
        assert(result.status == silly_transport::IoStatus.Ready
            || result.status == silly_transport::IoStatus.Interrupted);
        if result.status == silly_transport::IoStatus.Ready && events[0] != 0 {
            return;
        }
    }
    abort("head integration readiness timed out");
}

fn connect(port: i32) -> silly_transport::Descriptor {
    let result = silly_transport::connect("127.0.0.1", port);
    assert(result.status == silly_transport::IoStatus.Ready
        || result.status == silly_transport::IoStatus.WouldBlock);
    if result.status == silly_transport::IoStatus.WouldBlock {
        ready(result.descriptor, silly_transport::WRITE, now() + DEADLINE_MS);
        assert(silly_transport::finish_connect(result.descriptor).status == silly_transport::IoStatus.Ready);
    }
    return result.descriptor;
}

fn send_bytes(socket: silly_transport::Descriptor, bytes: u8[:]) {
    let deadline = now() + DEADLINE_MS;
    var offset = 0;
    while offset < bytes.len {
        assert(now() < deadline);
        let result = silly_transport::write_parts(socket, bytes[offset..], "");
        match result.status {
            Ready => {
                assert(result.count > 0);
                offset += result.count;
            },
            WouldBlock => {
                ready(socket, silly_transport::WRITE, deadline);
            },
            Interrupted => {
            },
            _ => {
                assert(false);
            },
        }
    }
}

fn receive_closed(socket: silly_transport::Descriptor) -> u8[>..] {
    var output: u8[>..] = [];
    var bytes: u8[1024] = [0; 1024];
    let deadline = now() + DEADLINE_MS;
    while now() < deadline {
        let result = silly_transport::read(socket, bytes);
        match result.status {
            Ready => {
                assert(result.count <= 4096 - output.len);
                output.append(bytes[..result.count]);
            },
            Closed => {
                return output;
            },
            WouldBlock => {
                ready(socket, silly_transport::READ, deadline);
            },
            Interrupted => {
            },
            _ => {
                assert(false);
            },
        }
    }
    abort("head integration response timed out");
}

fn request(port: i32, method: u8[:], path: u8[:], status: i32, body: u8[:]) {
    var client = connect(port);
    send_bytes(client, str(method, " ", path, " HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"));
    let response = receive_closed(client);
    assert(starts_with(response, str("HTTP/1.1 ", status, " ")));
    let separator = find(response, "\r\n\r\n");
    assert(separator >= 0);
    assert(response[separator + 4..] == body);
    if method == "HEAD" {
        assert(find(response, "Content-Length: 6\r\n") >= 0);
    }
    silly_transport::close(client);
}

fn invalid_before_listen() {
    // An occupied port would fail listen if preparation did not reject first.
    var occupied = silly_transport::listen("127.0.0.1", 0, 8);
    assert(occupied.status == silly_transport::IoStatus.Ready);
    let port = silly_transport::local_port(occupied.descriptor);
    assert(port.status == silly_transport::IoStatus.Ready);
    let result = silly::serve<Route>(silly::ServerOptions {
            port: port.count as i32,
            ..
        }, invalid, handle);
    assert(!result.ok);
    assert(result.error == silly::ServerError.Routes);
    assert(result.route_issue.route_id == 1);
    assert(result.route_issue.conflicting_route_id == 0);
    assert(definitions == 1);
    assert(handled == 0);
    definitions = 0;
    silly_transport::close(occupied.descriptor);
}

fn run() {
    invalid_before_listen();
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
    request(port.count as i32, "GET", "/items/new", 200, "static");
    request(port.count as i32, "GET", "/items/42", 200, "capture");
    request(port.count as i32, "GET", "/assets/css/main.css", 200, "wildcard");
    request(port.count as i32, "POST", "/items", 200, "post");
    request(port.count as i32, "GET", "/items/42/extra", 404, "");
    request(port.count as i32, "HEAD", "/items/new", 200, "");
    request(port.count as i32, "GET", "/items/new?sort=asc", 200, "static");
    request(port.count as i32, "GET", "http://localhost/items/new?x=1", 200, "static");
    assert(silly_transport::notify(wake.writer).status == silly_transport::IoStatus.Ready);
    let stopped, present = qget<Stopped>(DEADLINE_MS);
    assert(present);
    assert(stopped.ok);
    assert(stopped.definitions == 1);
    assert(stopped.handled == 7);
    assert(thread_wait(worker));
    silly_transport::close(wake.writer);
    print("prepared route socket dispatch passed");
}

fn::main() {
    route_server_test::run();
}
