// Bodyless responses never invoke production; persistent stream boundaries retain exact wire framing.
namespace stream_framing_test;

import silly from "../../";

import std;

import.body_socket_fixture;
import.connection_socket_fixture;

struct App {
}
enum Route {
    Normal,
    Empty,
    Reset,
    Cached
}
struct State {
    calls: i64 = 0,
    status: i32
}
struct Finished {
    status: i32,
    calls: i64,
    cancelled: bool
}
struct Started {
    ok: bool = true
}
struct Stopped {
    ok: bool
}
type Context = silly::Context<App, State>;

fn routes(router: silly::Router<Route>&, app: App&) {
    router.get("/normal", Route.Normal);
    router.head("/normal", Route.Normal);
    router.get("/empty", Route.Empty);
    router.get("/reset", Route.Reset);
    router.get("/cached", Route.Cached);
}

fn handle(ctx: Context&, route: Route) {
    let status: i32 = match route {
        Normal => 200,
        Empty => 204,
        Reset => 205,
        Cached => 304,
    };
    assert(ctx.stream(status, State {
            status: status,
            ..
        }, silly::StreamOptions {
            pending_bytes_max: 3,
            ..
        }) == silly::ResponseError.None);
}

fn step(state: State&, event: silly::StreamEvent, out: silly::ChunkWriter&) -> silly::StreamStep {
    if event == silly::StreamEvent.Cancelled {
        assert(qput(Finished {
                status: state.status,
                calls: state.calls,
                cancelled: true
            }));
        return silly::StreamStep.Done;
    }
    assert(event == silly::StreamEvent.Ready);
    state.calls += 1;
    if state.calls == 2 {
        assert(qput(Finished {
                status: state.status,
                calls: state.calls,
                cancelled: false
            }));
        return silly::StreamStep.Done;
    }
    assert(silly::append(out, "xyz"));
    return silly::StreamStep.Chunk {
        flush: true,
        next: silly::Wake.Ready
    };
}

fn lifecycle(app: App&, event: silly::Lifecycle<Route>) -> silly::HookResult {
    match event {
        Start _ => {
            assert(qput(Started {
                }));
        },
        _ => {
        },
    }
    return silly::HookResult.Ok;
}

thread_fn server(listener: i32, wake: i32) {
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
    routes(router, app);
    let options = silly::ServerOptions {
        limits: silly::Limits {
            body_bytes_max: 0,
            output_bytes_max: 16,
            ..
        },
        connections_max: 1,
        response_head_bytes_max: 512,
        work_bytes_per_turn: 1,
        accepts_per_turn: 1,
        poll_timeout_ms: 10,
        ..
    };
    let result = silly::run_prepared_stream_server<Route, App, State>(options,
        silly_transport::Descriptor {
            fd: listener
        }, silly_transport::Descriptor {
            fd: wake
        },
        silly::prepare(router), app, handle, step, lifecycle);
    assert(qput(Stopped {
            ok: result.ok
        }));
}

fn terminal(status: i32, cancelled: bool) {
    let done, present = qget<Finished>(10000);
    assert(present);
    assert(done.status == status);
    assert(done.cancelled == cancelled);
    let expected = if cancelled {
        0
    } else {
        2
    };
    assert(done.calls == expected);
}

fn check_head(response: u8[:], offset: i64, status: i32) -> i64 {
    let tail = response[offset..];
    assert(starts_with(tail, str("HTTP/1.1 ", status, " ")));
    let end = find(tail, "\r\n\r\n");
    assert(end >= 0);
    let head = tail[..end];
    assert(find(head, "Transfer-Encoding:") < 0);
    if status == 205 {
        assert(find(head, "Content-Length: 0") >= 0);
    } else {
        assert(find(head, "Content-Length:") < 0);
    }
    return offset + end + 4;
}

fn pipeline(port: i32) {
    var socket = body_socket::connect(port);
    var requests: u8[>..] = [];
    requests.append(connection_socket::request("HEAD", "/normal", 1, ""));
    requests.append(connection_socket::request("GET", "/empty", 1, ""));
    requests.append(connection_socket::request("GET", "/reset", 1, ""));
    requests.append(connection_socket::request("GET", "/cached", 1, ""));
    requests.append(connection_socket::request("GET", "/normal", 1, "Connection: close\r\n"));
    body_socket::send_bytes(socket, requests);
    let response = body_socket::receive_closed(socket);
    var offset = check_head(response, 0, 200);
    offset = check_head(response, offset, 204);
    offset = check_head(response, offset, 205);
    offset = check_head(response, offset, 304);
    let tail = response[offset..];
    assert(starts_with(tail, "HTTP/1.1 200 "));
    let end = find(tail, "\r\n\r\n");
    assert(end > 0);
    assert(find(tail[..end], "Transfer-Encoding: chunked") >= 0);
    assert(tail[end + 4..] == "3\r\nxyz\r\n0\r\n\r\n");
    terminal(200, true);
    terminal(204, true);
    terminal(205, true);
    terminal(304, true);
    terminal(200, false);
    silly_transport::close(socket);
}

fn close_delimited(port: i32) {
    var socket = body_socket::connect(port);
    body_socket::send_bytes(socket, connection_socket::request("GET", "/normal", 0, "Connection: keep-alive\r\n"));
    let response = body_socket::receive_closed(socket);
    let end = find(response, "\r\n\r\n");
    assert(end > 0);
    assert(starts_with(response, "HTTP/1.0 200 "));
    assert(find(response[..end], "Transfer-Encoding:") < 0);
    assert(find(response[..end], "Content-Length:") < 0);
    assert(find(response[..end], "Connection: close") >= 0);
    assert(response[end + 4..] == "xyz");
    terminal(200, false);
    silly_transport::close(socket);
}

fn run() {
    qlimit<Started>(1);
    qlimit<Stopped>(1);
    qlimit<Finished>(8);
    var listener = silly_transport::listen("127.0.0.1", 0, 8);
    assert(listener.status == silly_transport::IoStatus.Ready);
    let port = silly_transport::local_port(listener.descriptor);
    assert(port.status == silly_transport::IoStatus.Ready);
    var wake = silly_transport::wake_pair();
    assert(wake.status == silly_transport::IoStatus.Ready);
    let owner = thread_spawn(server, listener.descriptor.fd, wake.reader.fd);
    listener.descriptor.fd = -1;
    wake.reader.fd = -1;
    let started, ready = qget<Started>(10000);
    assert(ready);
    pipeline(port.count as i32);
    close_delimited(port.count as i32);
    assert(silly_transport::notify(wake.writer).status == silly_transport::IoStatus.Ready);
    let stopped, done = qget<Stopped>(10000);
    assert(done);
    assert(stopped.ok);
    assert(thread_wait(owner));
    silly_transport::close(wake.writer);
    let extra, duplicate = qpoll<Finished>();
    assert(!duplicate);
}

fn::main() {
    stream_framing_test::run();
    print("stream bodyless, persistent and close-delimited framing passed");
}
