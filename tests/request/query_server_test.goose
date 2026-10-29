// Repeated terminal decoding failures must not corrupt retained route owners.
namespace query_server_test;

import silly from "../../";

import std;

import.body_socket_fixture;

type Context = silly::Context<silly::NoState, silly::NoStream>;
enum Route {
    Pairs,
    First
}
struct Stopped {
    ok: bool
}

fn define(router: silly::Router<Route>&) {
    router.get("/pairs", Route.Pairs);
    router.get("/first", Route.First);
}

fn handle(ctx: Context&, route: Route) {
    var scratch: u8[>..] = [];
    let options = silly::QueryOptions {
        pairs_max: 2,
        ..
    };
    match route {
        Pairs => {
            let pairs = silly::query_pairs(ctx, scratch, options);
            let value = silly::get(pairs, "id");
            ctx.respond_text(200, value.value);
        },
        First => {
            let value = silly::query(ctx, "id", scratch, options);
            ctx.respond_text(200, value.value);
        },
    }
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
            output_bytes_max: 128,
            ..
        },
        connections_max: 2,
        response_head_bytes_max: 256,
        buffer_bytes_max: 128 * 1024,
        work_bytes_per_turn: 5,
        accepts_per_turn: 2,
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
            ok: result.ok
        }));
}

fn request(port: i32, target: u8[:], status: i32, expected: u8[:]) {
    var socket = body_socket::connect(port);
    body_socket::send_bytes(socket, str("GET ", target, " HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"));
    let response = body_socket::receive_closed(socket);
    assert(starts_with(response, str("HTTP/1.1 ", status, " ")));
    let end = find(response, "\r\n\r\n");
    assert(end >= 0);
    assert(response[end + 4..] == expected);
    silly_transport::close(socket);
}

fn verify(port: i32) {
    for round in 3 {
        for path in["/pairs", "/first"] {
            request(port, str(path, "?id=%41"), 200, "A");
            request(port, str(path, "?id=ok&bad=%"), 400, "Invalid query");
            request(port, str(path, "?id=%42"), 200, "B");
            request(port, str(path, "?id=x&a=1&b=2"), 400, "Invalid query");
            request(port, str(path, "?id=stable"), 200, "stable");
        }
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
    assert(thread_wait(worker));
    silly_transport::close(wake.writer);
    print("repeated query rejection socket tests passed");
}

fn::main() {
    query_server_test::run();
}
