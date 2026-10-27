// Typed and raw JSON share transport while keeping their parsing/error contracts distinct.
namespace json_server_test;

import silly from "..";

import std;

import.body_socket_fixture;

struct Input {
    name: const u8[:],
    workspace_id: i64
}
struct Reply {
    workspace_id: i64,
    display_name: const u8[:]
}
struct App {
    typed: i64 = 0,
    raw: i64 = 0,
    leaked: bool = false
}
type Context = silly::Context<App, silly::NoStream>;
enum Route {
    Typed,
    Raw,
    Large
}
struct Stopped {
    ok: bool,
    typed: i64,
    raw: i64,
    leaked: bool
}
const ALIASES: silly::JsonAlias[2] = [
    silly::JsonAlias {
        field: "workspace_id",
        wire: "workspaceId"
    },
    silly::JsonAlias {
        field: "display_name",
        wire: "displayName"
    },
];

fn define(router: silly::Router<Route>&, app: App&) {
    router.post("/typed", Route.Typed);
    router.post("/raw", Route.Raw);
    router.get("/large", Route.Large);
}

fn handle(ctx: Context&, route: Route) {
    match route {
        Typed => {
            var scratch: u8[>..] = [];
            let input = silly::require_json<Input>(ctx, scratch, silly::JsonBindOptions {
                    aliases: ALIASES,
                    ..
                });
            var reply = Reply {
                workspace_id: input.workspace_id,
                display_name: input.name
            };
            ctx.json(201, reply, silly::JsonWriteOptions {
                    aliases: ALIASES,
                    ..
                });
            ctx.app.typed += 1;
        },
        Raw => {
            ctx.json_bytes(200, ctx.body());
            ctx.app.raw += 1;
        },
        Large => {
            let large: u8[256] = ['x'; 256];
            var reply = Reply {
                workspace_id: 1,
                display_name: large
            };
            ctx.json(200, reply);
            ctx.app.leaked = true;
        },
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
    define(router, app);
    let plan = silly::prepare(router);
    assert(plan.issue.error == silly::RouteError.None);
    let options = silly::ServerOptions {
        port: 0,
        limits: silly::Limits {
            body_bytes_max: 1024,
            output_bytes_max: 128,
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
    let result = silly::run_prepared_server(options,
        silly_transport::Descriptor {
            fd: listener
        }, silly_transport::Descriptor {
            fd: wake
        }, plan, app, handle);
    assert(qput(Stopped {
            ok: result.ok,
            typed: app.typed,
            raw: app.raw,
            leaked: app.leaked
        }));
}

fn request(port: i32, path: u8[:], body: u8[:], media: u8[:] = "application/json") -> u8[>..] {
    var socket = body_socket::connect(port);
    body_socket::send_bytes(socket, str(if path == "/large" {
            "GET"
        } else {
            "POST"
        }, " ", path,
        " HTTP/1.1\r\nHost: localhost\r\n",
        "Connection: close\r\nContent-Type: ", media, "\r\nContent-Length: ", body.len, "\r\n\r\n", body));
    let response = body_socket::receive_closed(socket);
    silly_transport::close(socket);
    return response;
}

fn exact(response: u8[:], status: i32, expected: u8[:]) {
    assert(starts_with(response, str("HTTP/1.1 ", status, " ")));
    let end = find(response, "\r\n\r\n");
    assert(end >= 0);
    assert(response[end + 4..] == expected);
    if status == 200 || status == 201 {
        assert(find(response, "Content-Type: application/json\r\n") >= 0);
    }
}

fn verify(port: i32) {
    let valid = "{\"name\":\"A\\u0042\",\"workspaceId\":7}";
    let expected = "{\"workspaceId\":7,\"displayName\":\"AB\"}";
    for round in 3 {
        exact(request(port, "/typed", valid), 201, expected);
        for bad in["{\"name\":\"x\"}", "{\"name\":\"x\",\"name\":\"y\",\"workspaceId\":7}",
            "{\"name\":\"x\",\"workspaceId\":7,\"extra\":0}", "{\"name\":12,\"workspaceId\":7}", "{\"name\":"] {
            exact(request(port, "/typed", bad), 400, "");
        }
        let opaque = " { \"id\":1,\"id\":2 } ";
        exact(request(port, "/raw", opaque, "text/plain"), 200, opaque);
        exact(request(port, "/typed", valid, "text/plain"), 415, "");
        exact(request(port, "/large", ""), 500, "");
        exact(request(port, "/typed", valid), 201, expected);
    }
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
    assert(stopped.typed == 6);
    assert(stopped.raw == 3);
    assert(!stopped.leaked);
    assert(thread_wait(worker));
    silly_transport::close(wake.writer);
    print("typed/raw JSON and repeated failure sockets passed");
}

fn::main() {
    json_server_test::run();
}
