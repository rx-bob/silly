// SSE uses ordinary header access and stream transport; disconnect stops waiting producers once.
namespace sse_server_test;

import silly from "..";

import std;

import.body_socket_fixture;
import.connection_socket_fixture;

extern fn silly_lifecycle_reset_close(fd: i32) -> i32;

struct App {
}
enum Route {
    Finite,
    Waiting
}
struct State {
    route: Route,
    last_id: u8[..32] = [],
    resource: silly_transport::Descriptor,
    calls: i64 = 0,
}
struct Started {
    ok: bool = true
}
struct Acquired {
    peer: i32
}
struct Waiting {
    ok: bool = true
}
struct Released {
    cancelled: bool,
    calls: i64
}
struct Stopped {
    ok: bool
}
type Context = silly::Context<App, State>;

fn define(router: silly::Router<Route>&, app: App&) {
    router.get("/events", Route.Finite);
    router.get("/waiting", Route.Waiting);
}

fn handle(ctx: Context&, route: Route) {
    var pair = silly_transport::wake_pair();
    assert(pair.status == silly_transport::IoStatus.Ready);
    assert(qput(Acquired {
            peer: pair.writer.fd
        }));
    var state = State {
        route: route,
        resource: pair.reader,
        ..
    };
    let last_id = ctx.header("Last-Event-ID");
    assert(last_id.present);
    assert(last_id.value == "41");
    state.last_id.append(last_id.value);
    assert(ctx.events(state, silly::SseOptions {
            pending_bytes_max: 64,
            cache_control: "no-store",
            ..
        }) == silly::ResponseError.None);
    state.last_id.clear();
    state.last_id.append("expired handler frame");
}

fn release(state: State&, cancelled: bool) {
    assert(state.resource.fd >= 0);
    assert(silly_transport::close(state.resource).status == silly_transport::IoStatus.Ready);
    assert(qput(Released {
            cancelled: cancelled,
            calls: state.calls
        }));
}

fn step(state: State&, event: silly::StreamEvent, out: silly::ChunkWriter&) -> silly::StreamStep {
    assert(state.last_id == "41");
    if event == silly::StreamEvent.Cancelled {
        release(state, true);
        return silly::StreamStep.Done;
    }
    assert(event == silly::StreamEvent.Ready);
    state.calls += 1;
    if state.route == Route.Waiting {
        assert(state.calls == 1);
        assert(qput(Waiting {
            }));
        return silly::StreamStep.Wait {
            wake: silly::Wake.After {
                delay_ms: 10000
            }
        };
    }
    if state.calls == 2 {
        release(state, false);
        return silly::StreamStep.Done;
    }
    assert(silly::sse_event(out, silly::SseEvent {
            data: "next",
            event: "tick",
            id: state.last_id,
            ..
        }));
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
    define(router, app);
    let options = silly::ServerOptions {
        limits: silly::Limits {
            body_bytes_max: 0,
            output_bytes_max: 32,
            ..
        },
        connections_max: 1,
        response_head_bytes_max: 512,
        work_bytes_per_turn: 2,
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

fn acquired() -> silly_transport::Descriptor {
    let item, present = qget<Acquired>(10000);
    assert(present);
    return silly_transport::Descriptor {
        fd: item.peer
    };
}

fn released(peer: silly_transport::Descriptor&, cancelled: bool, calls: i64) {
    let item, present = qget<Released>(10000);
    assert(present);
    assert(item.cancelled == cancelled);
    assert(item.calls == calls);
    var bytes: u8[1] = [0];
    assert(silly_transport::read(peer, bytes).status == silly_transport::IoStatus.Closed);
    silly_transport::close(peer);
}

fn finite(port: i32) {
    var socket = body_socket::connect(port);
    body_socket::send_bytes(socket, connection_socket::request("GET", "/events", 1,
        "Last-Event-ID:  41 \r\nConnection: close\r\n"));
    var peer = acquired();
    let response = body_socket::receive_closed(socket);
    let end = find(response, "\r\n\r\n");
    assert(end > 0);
    assert(starts_with(response, "HTTP/1.1 200 "));
    assert(find(response[..end], "Content-Type: text/event-stream\r\n") >= 0);
    assert(find(response[..end], "Cache-Control: no-store") >= 0);
    assert(find(response[..end], "Connection: close\r\n") >= 0);
    assert(find(response[end + 4..], "event: tick\nid: 41\ndata: next\n\n") > 0);
    assert(ends_with(response, "\r\n0\r\n\r\n"));
    released(peer, false, 2);
    silly_transport::close(socket);
}

fn disconnected(port: i32) {
    var socket = body_socket::connect(port);
    body_socket::send_bytes(socket, connection_socket::request("GET", "/waiting", 1, "Last-Event-ID: 41\r\n"));
    var peer = acquired();
    let waiting, present = qget<Waiting>(10000);
    assert(present);
    assert(silly_lifecycle_reset_close(socket.fd) == 0);
    silly_transport::close(socket);
    released(peer, true, 1);
}

fn run() {
    qlimit<Started>(1);
    qlimit<Stopped>(1);
    qlimit<Acquired>(1);
    qlimit<Released>(2);
    qlimit<Waiting>(1);
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
    finite(port.count as i32);
    disconnected(port.count as i32);
    assert(silly_transport::notify(wake.writer).status == silly_transport::IoStatus.Ready);
    let stopped, done = qget<Stopped>(10000);
    assert(done);
    assert(stopped.ok);
    assert(thread_wait(owner));
    silly_transport::close(wake.writer);
    let extra, duplicate = qpoll<Released>();
    assert(!duplicate);
}

fn::main() {
    sse_server_test::run();
    print("SSE metadata, Last-Event-ID ownership and disconnect cleanup passed");
}
