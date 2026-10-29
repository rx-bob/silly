// Real blocking native work and explicit foreign descriptors expose bounded shutdown ownership.
namespace shutdown_socket;

import native_bindings from "../../examples/promptnook_contract";
import silly from "../../";

import std;

import.body_socket_fixture;
import.connection_socket_fixture;
import.native_control;

enum Route {
    Inline,
    Blocking
}

struct App {
    owner: silly::Owner,
    mode: i64,
    resource: silly_transport::Descriptor = silly_transport::Descriptor {
    },
    stopped: bool = false,
}

struct ForeignResource {
    owned_fd: i32,
    peer_fd: i32,
}

struct Started {
    lane: i64
}
struct Stopped {
    lane: i64
}
struct Began {
    value: bool = true
}
struct RuntimeReturned {
    ok: bool,
    error: silly::ServerError,
    drain: silly::DrainStatus,
    pending: silly::ShutdownHandle,
    unrecovered_owners: u8,
}

struct Running {
    thread: i64,
    port: i32,
    wake: silly_transport::Descriptor,
    foreign: ForeignResource,
}

fn initialize(mode: i64, owner: silly::Owner) -> App {
    var resource = silly_transport::Descriptor {
    };
    if owner.lane == 0 {
        var pair = silly_transport::wake_pair();
        assert(pair.status == silly_transport::IoStatus.Ready);
        resource = pair.reader;
        assert(qput(ForeignResource {
                owned_fd: resource.fd,
                peer_fd: pair.writer.fd,
            }));
        pair.writer.fd = -1;
    }
    return App {
        owner: owner,
        mode: mode,
        resource: resource,
        ..
    };
}

fn define(router: silly::Router<Route>&, app: App&) {
    router.get("/inline", Route.Inline);
    router.get("/blocking", Route.Blocking, silly::RouteOptions {
            execution: silly::Execution.Serialized {
                lane: "native_shutdown"
            },
            ..
        });
}

fn handle(ctx: silly::Context<App, silly::NoStream> & , route: Route) {
    if route == Route.Inline {
        ctx.text(200, str("listener:", ctx.request.listener_id));
        return;
    }
    assert(ctx.app.owner.is_serialized("native_shutdown"));
    assert(promptnook_native_example::promptnook_contract_prepare(37) == 0);
    assert(promptnook_native_example::promptnook_contract_bind(37) == 0);
    assert(qput(Began {
        }));
    if ctx.app.mode == 1 {
        abort("contained shutdown fixture abort");
    }
    assert(promptnook_native_example::promptnook_contract_query() == 0);
    let value = promptnook_native_example::promptnook_contract_read();
    assert(value == 377);
    ctx.text(200, str("listener:", ctx.request.listener_id, ":", value));
}

fn lifecycle(app: App&, event: silly::Lifecycle<Route>) -> silly::HookResult {
    match event {
        Start start => {
            if app.owner.lane == 0 {
                assert(promptnook_native_example::promptnook_contract_open() == 0);
            }
            assert(qput(Started {
                    lane: app.owner.lane
                }));
        },
        Stop stop => {
            assert(!app.stopped);
            app.stopped = true;
            if app.owner.lane == 0 {
                assert(promptnook_native_example::promptnook_contract_close() == 0);
                assert(silly_transport::close(app.resource).status == silly_transport::IoStatus.Ready);
            }
            assert(qput(Stopped {
                    lane: app.owner.lane
                }));
        },
        _ => {
        },
    }
    return silly::HookResult.Ok;
}

thread_fn io_worker(start: silly::WorkerStart, mode: i64) {
    silly::run_runtime_worker<Route>(start, mode, initialize, define, handle, lifecycle);
}

thread_fn lane_worker(start: silly::LaneStart, mode: i64) {
    silly::run_executor_lane<Route>(start, mode, initialize, define, handle, lifecycle);
}

fn options(timeout: i64) -> silly::RuntimeOptions {
    return silly::RuntimeOptions {
        shutdown_timeout_ms: timeout,
        worker: silly::WorkerOptions {
            connections_max: 4,
            accepts_per_turn: 4,
            poll_timeout_ms: 10,
            ..
        },
        executor: silly::ExecutorOptions {
            serialized_name: "native_shutdown",
            lanes: 1,
            queue_max: 1,
            outstanding_per_owner: 2,
            task_timeout_ms: 10000,
            ..
        },
        ..
    };
}

thread_fn supervisor(listener: i32, wake: i32, mode: i64) {
    let result = silly::run_runtime_with_executor(options(if mode == 2 {
            5000
        } else {
            50
        }), silly_transport::Descriptor {
            fd: listener
        },
        silly_transport::Descriptor {
            fd: wake
        }, mode, io_worker, lane_worker);
    assert(qput(RuntimeReturned {
            ok: result.ok,
            error: result.error,
            drain: result.drain,
            pending: result.pending,
            unrecovered_owners: result.unrecovered_owners,
        }));
}

fn start(mode: i64 = 0) -> Running {
    assert(native_control::native_test_reset(0) == 0);
    qlimit<ForeignResource>(1);
    qlimit<Started>(2);
    qlimit<Stopped>(2);
    qlimit<Began>(8);
    qlimit<RuntimeReturned>(1);
    var listener = silly_transport::listen("127.0.0.1", 0, 16);
    assert(listener.status == silly_transport::IoStatus.Ready);
    let port = silly_transport::local_port(listener.descriptor);
    assert(port.status == silly_transport::IoStatus.Ready);
    var wake = silly_transport::wake_pair();
    assert(wake.status == silly_transport::IoStatus.Ready);
    let thread = thread_spawn(supervisor, listener.descriptor.fd, wake.reader.fd, mode);
    listener.descriptor.fd = -1;
    wake.reader.fd = -1;
    let first, has_first = qget<Started>(10000);
    let second, has_second = qget<Started>(10000);
    assert(has_first);
    assert(has_second);
    assert(first.lane != second.lane);
    let foreign, has_foreign = qget<ForeignResource>(10000);
    assert(has_foreign);
    return Running {
        thread: thread,
        port: port.count as i32,
        wake: wake.writer,
        foreign: foreign
    };
}

fn returned(running: Running&) -> RuntimeReturned {
    let result, present = qget<RuntimeReturned>(10000);
    assert(present);
    assert(thread_wait(running.thread));
    return result;
}

fn resource_open(resource: ForeignResource) {
    var byte: u8[1] = [0];
    assert(silly_transport::read(silly_transport::Descriptor {
            fd: resource.peer_fd
        }, byte).status
        == silly_transport::IoStatus.WouldBlock);
}

fn close_peer(resource: ForeignResource) {
    var peer = silly_transport::Descriptor {
        fd: resource.peer_fd
    };
    var byte: u8[1] = [0];
    assert(silly_transport::read(peer, byte).status == silly_transport::IoStatus.Closed);
    silly_transport::close(peer);
}

fn stopped() {
    let first, has_first = qget<Stopped>(10000);
    let second, has_second = qget<Stopped>(10000);
    assert(has_first);
    assert(has_second);
    assert(first.lane != second.lane);
    let extra, has_extra = qpoll<Stopped>();
    assert(!has_extra);
    assert(native_control::native_test_metric(1) == 1);
}
