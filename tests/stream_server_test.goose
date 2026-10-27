// Real producer dispatch, bounded short writes and terminal ownership through the public server.
namespace stream_server_test;

import silly from "..";

import std;

import.body_socket_fixture;
import.connection_socket_fixture;

extern fn silly_lifecycle_reset_close(fd: i32) -> i32;

var handler_finished: bool = false;

struct App {
    starts: i64 = 0,
    handlers: i64 = 0,
    transfers: i64 = 0,
    stops: i64 = 0,
}
enum Route {
    Sequence,
    Before,
    After,
    Waiting
}
struct State {
    route: Route,
    label: u8[..3],
    resource: silly_transport::Descriptor,
    calls: i64 = 0,
    released: bool = false,
}
type Context = silly::Context<App, State>;
struct Record {
    kind: i32,
    data: silly::CompletionData = silly::CompletionData {
    },
}
struct Acquired {
    peer: i32
}
struct Released {
    route: Route,
    cancelled: bool,
    calls: i64
}
struct Waiting {
    value: bool = true
}
struct Stopped {
    ok: bool,
    app: App
}

fn define(router: silly::Router<Route>&, app: App&) {
    router.get("/sequence", Route.Sequence);
    router.get("/before", Route.Before);
    router.get("/after", Route.After);
    router.get("/waiting", Route.Waiting);
}

fn handle(ctx: Context&, route: Route) {
    handler_finished = false;
    var pair = silly_transport::wake_pair();
    assert(pair.status == silly_transport::IoStatus.Ready);
    assert(qput(Acquired {
            peer: pair.writer.fd
        }));
    var state = State {
        route: route,
        label: [],
        resource: pair.reader,
        ..
    };
    state.label.append("abc");
    assert(ctx.stream(200, state, silly::StreamOptions {
            content_type: "application/octet-stream",
            pending_bytes_max: 3,
            ..
        }) == silly::ResponseError.None);
    state.label.clear();
    state.label.append("bad");
}

fn release(state: State&, cancelled: bool) {
    assert(!state.released);
    state.released = true;
    assert(silly_transport::close(state.resource).status == silly_transport::IoStatus.Ready);
    assert(qput(Released {
            route: state.route,
            cancelled: cancelled,
            calls: state.calls
        }));
}

fn step(state: State&, event: silly::StreamEvent, out: silly::ChunkWriter&) -> silly::StreamStep {
    assert(handler_finished);
    assert(state.label == "abc");
    if event == silly::StreamEvent.Cancelled {
        assert(out.bytes.len == 0);
        release(state, true);
        return silly::StreamStep.Done;
    }
    assert(event == silly::StreamEvent.Ready);
    state.calls += 1;
    if state.route == Route.Before || (state.route == Route.After && state.calls == 2) {
        return silly::StreamStep.Failed {
            reason: silly::StreamError.Input
        };
    }
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
    if state.calls == 4 {
        release(state, false);
        return silly::StreamStep.Done;
    }
    assert(out.bytes.len == 3);
    assert(silly::append(out, state.label));
    return silly::StreamStep.Chunk {
        flush: state.calls == 2,
        next: silly::Wake.After {
            delay_ms: 1
        }
    };
}

fn lifecycle(app: App&, event: silly::Lifecycle<Route>) -> silly::HookResult {
    var kind: i32 = 0;
    var data = silly::CompletionData {
    };
    match event {
        Start _ => {
            app.starts += 1;
            kind = 1;
        },
        HandlerFinished done => {
            assert(!handler_finished);
            handler_finished = true;
            app.handlers += 1;
            data = done.completion.data;
            kind = 2;
        },
        TransferFinished done => {
            assert(handler_finished);
            app.transfers += 1;
            assert(app.transfers == app.handlers);
            data = done.completion.data;
            kind = 3;
        },
        Stop _ => {
            assert(app.transfers == app.handlers);
            app.stops += 1;
            kind = 4;
        },
    }
    assert(qput(Record {
            kind: kind,
            data: data
        }));
    return silly::HookResult.Ok;
}

fn options() -> silly::ServerOptions {
    return silly::ServerOptions {
        limits: silly::Limits {
            body_bytes_max: 0,
            output_bytes_max: 64,
            ..
        },
        connections_max: 2,
        response_head_bytes_max: 512,
        buffer_bytes_max: 128 * 1024,
        work_bytes_per_turn: 2,
        accepts_per_turn: 2,
        poll_timeout_ms: 10,
        idle_timeout_ms: 30000,
        ..
    };
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
    let result = silly::run_prepared_stream_server<Route, App, State>(options(),
        silly_transport::Descriptor {
            fd: listener
        }, silly_transport::Descriptor {
            fd: wake
        },
        plan, app, handle, step, lifecycle);
    assert(qput(Stopped {
            ok: result.ok,
            app: app
        }));
}

fn record(kind: i32) -> silly::CompletionData {
    let item, present = qget<Record>(10000);
    assert(present);
    assert(item.kind == kind);
    return item.data;
}

fn acquired() -> silly_transport::Descriptor {
    let item, present = qget<Acquired>(10000);
    assert(present);
    return silly_transport::Descriptor {
        fd: item.peer
    };
}

fn released(peer: silly_transport::Descriptor&, route: Route, cancelled: bool, calls: i64) {
    let item, present = qget<Released>(10000);
    assert(present);
    assert(item.route == route);
    assert(item.cancelled == cancelled);
    assert(item.calls == calls);
    var bytes: u8[1] = [0];
    assert(silly_transport::read(peer, bytes).status == silly_transport::IoStatus.Closed);
    silly_transport::close(peer);
    let extra, duplicate = qpoll<Released>();
    assert(!duplicate);
}

fn ordinary(port: i32, route: Route, minor: i32) {
    let path = if route == Route.Sequence {
        "/sequence"
    } else if route == Route.Before {
        "/before"
    } else {
        "/after"
    };
    var socket = body_socket::connect(port);
    body_socket::send_bytes(socket, connection_socket::request("GET", path, minor, "Connection: close\r\n"));
    var peer = acquired();
    assert(record(2).status == 200);
    let response = body_socket::receive_closed(socket);
    let end = find(response, "\r\n\r\n");
    assert(end >= 0);
    let transferred = record(3);
    assert(transferred.wire_bytes == response.len);
    if route == Route.Before {
        assert(starts_with(response, str("HTTP/1.", minor, " 500 ")));
        assert(response[end + 4..] == "");
        assert(transferred.status == 500);
        released(peer, route, true, 1);
    } else {
        assert(starts_with(response, str("HTTP/1.", minor, " 200 ")));
        assert(find(response, "Content-Type: application/octet-stream\r\n") >= 0);
        assert(find(response[end + 4..], "HTTP/1.") < 0);
        if route == Route.Sequence {
            let expected = if minor == 1 {
                "3\r\nabc\r\n3\r\nabc\r\n3\r\nabc\r\n0\r\n\r\n"
            } else {
                "abcabcabc"
            };
            assert(response[end + 4..] == expected);
            assert(transferred.transfer == silly::TransferOutcome.Delivered);
            released(peer, route, false, 4);
        } else {
            let expected = if minor == 1 {
                "3\r\nabc\r\n"
            } else {
                "abc"
            };
            assert(response[end + 4..] == expected);
            assert(transferred.transfer != silly::TransferOutcome.Delivered);
            released(peer, route, true, 2);
        }
    }
    silly_transport::close(socket);
}

fn waiting(port: i32) -> silly_transport::Descriptor {
    var socket = body_socket::connect(port);
    body_socket::send_bytes(socket, connection_socket::request("GET", "/waiting", 1, "Connection: close\r\n"));
    record(2);
    let item, present = qget<Waiting>(10000);
    assert(present);
    return socket;
}

fn six_argument_shape() {
    var app = App {
    };
    var invalid = options();
    invalid.connections_max = 0;
    let result = silly::serve<Route, App, State>(invalid, app, define, handle, step, lifecycle);
    assert(!result.ok);
    assert(result.error == silly::ServerError.InvalidOptions);
    assert(app.starts == 0);
}

fn run() {
    qlimit<Record>(16);
    qlimit<Acquired>(2);
    qlimit<Released>(2);
    qlimit<Waiting>(2);
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
    record(1);
    for minor in 2 {
        ordinary(port.count as i32, Route.Sequence, minor as i32);
        ordinary(port.count as i32, Route.Before, minor as i32);
        ordinary(port.count as i32, Route.After, minor as i32);
    }
    var reset = waiting(port.count as i32);
    var peer = acquired();
    assert(silly_lifecycle_reset_close(reset.fd) == 0);
    silly_transport::close(reset);
    assert(record(3).transfer == silly::TransferOutcome.Cancelled);
    released(peer, Route.Waiting, true, 1);
    var pending = waiting(port.count as i32);
    peer = acquired();
    assert(silly_transport::notify(wake.writer).status == silly_transport::IoStatus.Ready);
    assert(record(3).transfer == silly::TransferOutcome.Cancelled);
    released(peer, Route.Waiting, true, 1);
    record(4);
    let result, present = qget<Stopped>(10000);
    assert(present);
    assert(result.ok);
    assert(result.app.starts == 1);
    assert(result.app.stops == 1);
    assert(result.app.handlers == 8);
    assert(result.app.transfers == 8);
    assert(thread_wait(worker));
    silly_transport::close(pending);
    silly_transport::close(wake.writer);
    let extra, duplicate = qpoll<Record>();
    assert(!duplicate);
}

fn::main() {
    stream_server_test::six_argument_shape();
    stream_server_test::run();
    print("stream server short writes, lifecycle, failure and cancellation passed");
}
