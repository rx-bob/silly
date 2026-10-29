// Two independent execution lanes expose explicit handshakes for deterministic ordering tests.
namespace executor_socket;

import silly from "../../";

import std;

import.body_socket_fixture;
import.connection_socket_fixture;

enum Route {
    Inline,
    First,
    Second,
    Large
}

struct App {
    owner: i64,
    lane: bool,
    handlers: i64 = 0,
    transfers: i64 = 0,
}

struct Started {
    owner: i64,
    lane: bool,
}

struct Stopped {
    app: App,
}

struct Began {
    lane: i64,
    marker: u8[..32],
}

struct ReleaseFirst {
    ready: bool = true,
}

struct ReleaseSecond {
    ready: bool = true,
}

struct RuntimeDone {
    ok: bool,
    error: silly::ServerError,
}

struct Cancelled {
    owner: i64,
}

struct LaneHandled {
    lane: i64,
}

struct Running {
    thread: i64,
    port: i32,
    wake: silly_transport::Descriptor,
}

fn io_initialize(seed: i64, owner: silly::Owner) -> App {
    return App {
        owner: owner.id,
        lane: false,
        ..
    };
}

fn lane_initialize(seed: i64, owner: silly::Owner) -> App {
    return App {
        owner: owner.id,
        lane: true,
        ..
    };
}

fn define(router: silly::Router<Route>&, app: App&) {
    router.get("/inline", Route.Inline);
    router.post("/first", Route.First, silly::RouteOptions {
            execution: silly::ExecutionClass.Lane {
                index: 0
            },
            ..
        });
    router.post("/second", Route.Second, silly::RouteOptions {
            execution: silly::ExecutionClass.Lane {
                index: 1
            },
            ..
        });
    router.post("/large", Route.Large, silly::RouteOptions {
            execution: silly::ExecutionClass.Lane {
                index: 0
            },
            ..
        });
}

fn handle(ctx: silly::Context<App, silly::NoStream> & , route: Route) {
    let marker = ctx.header("X-Marker").value;
    if route == Route.Inline {
        assert(!ctx.app.lane);
        ctx.text(200, str("io:", ctx.app.owner, ":", marker));
        return;
    }
    assert(ctx.app.lane);
    if route == Route.Large {
        let bytes: u8[1024] = ['x'; 1024];
        ctx.bytes(200, bytes);
        return;
    }
    assert(qput(Began {
            lane: ctx.app.owner,
            marker: marker,
        }));
    if route == Route.First {
        let release, present = qget<ReleaseFirst>(10000);
        assert(present);
        assert(release.ready);
    } else {
        let release, present = qget<ReleaseSecond>(10000);
        assert(present);
        assert(release.ready);
    }
    match ctx.request.body_state {
        Buffered body => {
            ctx.text(200, str("lane:", ctx.app.owner, ":", marker, ":", body.bytes));
        },
        _ => {
            abort("executor did not reconstruct a buffered request");
        },
    }
}

fn lifecycle(app: App&, event: silly::Lifecycle<Route>) -> silly::HookResult {
    match event {
        Start start => {
            assert(start.owner.id == app.owner);
            assert(qput(Started {
                    owner: app.owner,
                    lane: app.lane,
                }));
        },
        HandlerFinished done => {
            app.handlers += 1;
            if app.lane {
                assert(qput(LaneHandled {
                        lane: app.owner
                    }));
            }
        },
        TransferFinished done => {
            assert(!app.lane);
            app.transfers += 1;
            if done.completion.data.transfer == silly::TransferOutcome.Cancelled {
                assert(qput(Cancelled {
                        owner: app.owner
                    }));
            }
        },
        Stop stop => {
            assert(stop.owner.id == app.owner);
            assert(qput(Stopped {
                    app: app
                }));
        },
    }
    return silly::HookResult.Ok;
}

thread_fn io_worker(start: silly::WorkerStart, seed: i64) {
    silly::run_runtime_worker<Route>(start, seed, io_initialize, define, handle, lifecycle);
}

thread_fn lane_worker(start: silly::LaneStart, seed: i64) {
    silly::run_executor_lane_with_errors<Route>(start, seed, lane_initialize, define, handle, lifecycle, lane_error);
}

fn lane_error(response: silly::Response&, failure: silly::ResponseFailure) {
    assert(silly::begin_response(response, failure.status) == silly::ResponseError.None);
    assert(silly::append_body(response, "from-lane") == silly::ResponseError.None);
    assert(silly::prepare_response(response) == silly::ResponseError.None);
}

thread_fn supervisor(listener: i32, wake: i32, timeout: i64) {
    let options = silly::RuntimeOptions {
        workers: 2,
        accept_queue_max: 4,
        worker: silly::WorkerOptions {
            limits: silly::Limits {
                head_bytes_max: 2048,
                body_bytes_max: 2048,
                output_bytes_max: 2048,
                ..
            },
            connections_max: 4,
            response_head_bytes_max: 2048,
            accepts_per_turn: 1,
            dispatches_per_turn: 1,
            idle_timeout_ms: 15000,
            poll_timeout_ms: 10,
            ..
        },
        executor: silly::ExecutorOptions {
            lanes: 2,
            independent_lanes: true,
            queue_max: 1,
            outstanding_per_owner: 2,
            head_bytes_max: 1024,
            body_bytes_max: 512,
            response_head_bytes_max: 1024,
            response_body_bytes_max: 512,
            task_timeout_ms: timeout,
            ..
        },
        ..
    };
    let result = silly::run_runtime_with_executor(options, silly_transport::Descriptor {
            fd: listener
        }, silly_transport::Descriptor {
            fd: wake
        }, 0, io_worker, lane_worker);
    assert(qput(RuntimeDone {
            ok: result.ok,
            error: result.error,
        }));
}

fn start(timeout: i64 = 10000) -> Running {
    qlimit<Started>(4);
    qlimit<Stopped>(4);
    qlimit<Began>(8);
    qlimit<ReleaseFirst>(8);
    qlimit<ReleaseSecond>(8);
    qlimit<RuntimeDone>(1);
    qlimit<Cancelled>(16);
    qlimit<LaneHandled>(16);
    var listener = silly_transport::listen("127.0.0.1", 0, 16);
    assert(listener.status == silly_transport::IoStatus.Ready);
    let port = silly_transport::local_port(listener.descriptor);
    assert(port.status == silly_transport::IoStatus.Ready);
    var wake = silly_transport::wake_pair();
    assert(wake.status == silly_transport::IoStatus.Ready);
    let thread = thread_spawn(supervisor, listener.descriptor.fd, wake.reader.fd, timeout);
    listener.descriptor.fd = -1;
    wake.reader.fd = -1;
    var seen: bool[4] = [false; 4];
    for index in 4 {
        let event, present = qget<Started>(10000);
        assert(present);
        let slot = event.owner + (if event.lane {
                2
            } else {
                0
            });
        assert(slot >= 0);
        assert(slot < 4);
        assert(!seen[slot]);
        seen[slot] = true;
    }
    return Running {
        thread: thread,
        port: port.count as i32,
        wake: wake.writer,
    };
}

fn inline_request(socket: silly_transport::Descriptor, owner: i64, marker: u8[:]) {
    body_socket::send_bytes(socket, connection_socket::request("GET", "/inline", 1,
        str("X-Marker: ", marker, "\r\n")));
    connection_socket::exact(connection_socket::receive(socket), 1, 200, str("io:", owner, ":", marker));
}

fn send_lane(socket: silly_transport::Descriptor, lane: i64, marker: u8[:], body: u8[:] = "payload") {
    body_socket::send_bytes(socket, connection_socket::request("POST", if lane == 0 {
            "/first"
        } else {
            "/second"
        },
        1, str("X-Marker: ", marker, "\r\n"), body));
}

fn began(lane: i64, marker: u8[:]) {
    let event, present = qget<Began>(10000);
    assert(present);
    assert(event.lane == lane);
    assert(event.marker == marker);
}

fn release(lane: i64) {
    if lane == 0 {
        assert(qput(ReleaseFirst {
            }));
    } else {
        assert(qput(ReleaseSecond {
            }));
    }
}

fn lane_response(socket: silly_transport::Descriptor, lane: i64, marker: u8[:]) {
    connection_socket::exact(connection_socket::receive(socket), 1, 200, str("lane:", lane, ":", marker, ":payload"));
}

fn finish(running: Running&, lane_handlers: i64) {
    assert(silly_transport::notify(running.wake).status == silly_transport::IoStatus.Ready);
    joined(running, lane_handlers);
}

fn joined(running: Running&, lane_handlers: i64) {
    let done, present = qget<RuntimeDone>(10000);
    assert(present);
    assert(done.ok);
    assert(done.error == silly::ServerError.None);
    assert(thread_wait(running.thread));
    var handlers: i64 = 0;
    for index in 4 {
        let event, stopped = qpoll<Stopped>();
        assert(stopped);
        if event.app.lane {
            handlers += event.app.handlers;
            assert(event.app.transfers == 0);
        }
    }
    assert(handlers == lane_handlers);
    let extra, remains = qpoll<Stopped>();
    assert(!remains);
    let waiting, admitted = qpoll<Began>();
    assert(!admitted);
    for index in 16 {
        let cancelled, has_cancelled = qpoll<Cancelled>();
        let handled, has_handled = qpoll<LaneHandled>();
        if !has_cancelled && !has_handled {
            break;
        }
    }
    silly_transport::close(running.wake);
}
