// A stopped TCP reader exhausts finite transport capacity and pauses the real producer.
namespace stream_backpressure_test;

import silly from "..";

import std;

import.body_socket_fixture;
import.connection_socket_fixture;

var produced: i64 = 0;
struct App {
    started: bool = false
}
struct State {
    cancelled: bool = false
}
enum Route {
    Flood,
    Snapshot
}
type Context = silly::Context<App, State>;
struct Started {
    value: bool = true
}
struct Began {
    value: bool = true
}
struct Released {
    calls: i64
}
struct Finished {
    outcome: silly::TransferOutcome
}
struct Stopped {
    ok: bool
}

fn define(router: silly::Router<Route>&, app: App&) {
    router.get("/flood", Route.Flood);
    router.get("/snapshot", Route.Snapshot);
}

fn handle(ctx: Context&, route: Route) {
    if route == Route.Snapshot {
        ctx.text(200, str(produced));
        return;
    }
    assert(ctx.stream(200, State {
        }, silly::StreamOptions {
            pending_bytes_max: 4096,
            ..
        })
        == silly::ResponseError.None);
}

fn step(state: State&, event: silly::StreamEvent, out: silly::ChunkWriter&) -> silly::StreamStep {
    if event == silly::StreamEvent.Cancelled {
        assert(!state.cancelled);
        state.cancelled = true;
        assert(qput(Released {
                calls: produced
            }));
        return silly::StreamStep.Done;
    }
    assert(event == silly::StreamEvent.Ready);
    produced += 1;
    assert(produced < 16384);
    let bytes: u8[4096] = ['x'; 4096];
    assert(silly::append(out, bytes));
    return silly::StreamStep.Chunk {
        flush: false,
        next: silly::Wake.Ready
    };
}

fn lifecycle(app: App&, event: silly::Lifecycle<Route>) -> silly::HookResult {
    match event {
        Start _ => {
            assert(!app.started);
            app.started = true;
            assert(qput(Started {
                }));
        },
        HandlerFinished done => {
            if done.completion.data.target == "/flood" {
                assert(qput(Began {
                    }));
            }
        },
        TransferFinished done => {
            if done.completion.data.target == "/flood" {
                assert(qput(Finished {
                        outcome: done.completion.data.transfer
                    }));
            }
        },
        _ => {
        },
    }
    return silly::HookResult.Ok;
}

thread_fn serve(listener: i32, wake: i32) {
    produced = 0;
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
            output_bytes_max: 64,
            ..
        },
        connections_max: 2,
        response_head_bytes_max: 512,
        buffer_bytes_max: 128 * 1024,
        work_bytes_per_turn: 4096,
        accepts_per_turn: 2,
        dispatches_per_turn: 2,
        poll_timeout_ms: 10,
        idle_timeout_ms: 60000,
        write_timeout_ms: 60000,
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

fn snapshot(port: i32) -> i64 {
    var socket = body_socket::connect(port);
    body_socket::send_bytes(socket, connection_socket::request("GET", "/snapshot", 1, "Connection: close\r\n"));
    let response = body_socket::receive_closed(socket);
    assert(starts_with(response, "HTTP/1.1 200 "));
    let end = find(response, "\r\n\r\n");
    assert(end >= 0);
    var number: i64 = 0;
    for byte in response[end + 4..] {
        assert(byte >= '0');
        assert(byte <= '9');
        number = number * 10 + (byte - '0');
    }
    silly_transport::close(socket);
    return number;
}

fn paused(port: i32) -> i64 {
    var previous: i64 = -1;
    var same: i64 = 0;
    for attempt in 1024 {
        let current = snapshot(port);
        assert(current < 16384);
        if current > 0 && current == previous {
            same += 1;
        } else {
            same = 0;
        }
        if same == 4 {
            return current;
        }
        previous = current;
    }
    abort("slow reader never stopped producer");
}

fn resumed(socket: silly_transport::Descriptor, port: i32, before: i64) {
    var bytes: u8[16384] = [0; 16384];
    let deadline = body_socket::now() + 10000;
    for attempt in 1024 {
        assert(body_socket::now() < deadline);
        let read = silly_transport::read(socket, bytes);
        assert(read.status == silly_transport::IoStatus.Ready || read.status == silly_transport::IoStatus.WouldBlock);
        if snapshot(port) > before {
            return;
        }
        if read.status == silly_transport::IoStatus.WouldBlock {
            body_socket::ready(socket, silly_transport::READ, deadline);
        }
    }
    abort("draining output never resumed producer");
}

fn run() {
    qlimit<Started>(1);
    qlimit<Began>(1);
    qlimit<Released>(1);
    qlimit<Finished>(1);
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
    let start, has_start = qget<Started>(10000);
    assert(has_start);
    var socket = body_socket::connect(port.count as i32);
    assert(silly_transport::set_receive_buffer(socket, 1024).status == silly_transport::IoStatus.Ready);
    body_socket::send_bytes(socket, connection_socket::request("GET", "/flood", 1, "Connection: close\r\n"));
    let begun, has_begun = qget<Began>(10000);
    assert(has_begun);
    let before = paused(port.count as i32);
    resumed(socket, port.count as i32, before);
    assert(silly_transport::notify(wake.writer).status == silly_transport::IoStatus.Ready);
    let release, has_release = qget<Released>(10000);
    assert(has_release);
    assert(release.calls > before);
    let finished, has_finished = qget<Finished>(10000);
    assert(has_finished);
    assert(finished.outcome == silly::TransferOutcome.Cancelled);
    let stopped, has_stopped = qget<Stopped>(10000);
    assert(has_stopped);
    assert(stopped.ok);
    assert(thread_wait(worker));
    let duplicate, has_duplicate = qpoll<Released>();
    assert(!has_duplicate);
    silly_transport::close(socket);
    silly_transport::close(wake.writer);
}

fn::main() {
    stream_backpressure_test::run();
    print("real slow reader pauses and resumes bounded producer");
}
