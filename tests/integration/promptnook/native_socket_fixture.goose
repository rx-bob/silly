// Native ownership test handshakes; no production DB or ZIP implementation is linked.
namespace native_socket;

import native_state from "../../../examples/promptnook_contract";
import silly from "../../../";

import std;

import.body_socket_fixture;
import.connection_socket_fixture;

struct Started {
    owner: silly::Owner,
    native: bool
}
struct Stopped {
    owner: silly::Owner,
    native: bool,
    opened: bool
}
struct HandlerDone {
    native: bool
}
struct RuntimeDone {
    ok: bool,
    error: silly::ServerError
}
struct Running {
    thread: i64,
    port: i32,
    wake: silly_transport::Descriptor,
    lanes: i64
}

fn lifecycle(app: promptnook_native_example::App&,
    event: silly::Lifecycle<promptnook_native_example::Route>) -> silly::HookResult {
    let result = promptnook_native_example::lifecycle(app, event);
    match event {
        Start started => {
            assert(qput(Started {
                    owner: started.owner,
                    native: app.owns_native
                }));
        },
        HandlerFinished done => {
            assert(qput(HandlerDone {
                    native: app.owns_native
                }));
        },
        Stop stopped => {
            assert(qput(Stopped {
                    owner: stopped.owner,
                    native: app.owns_native,
                    opened: app.opened
                }));
        },
        _ => {
        },
    }
    return result;
}

thread_fn io_worker(start: silly::WorkerStart, seed: i64) {
    silly::run_runtime_worker<promptnook_native_example::Route>(start, seed,
        promptnook_native_example::initialize, promptnook_native_example::routes,
        promptnook_native_example::handle, lifecycle);
}

thread_fn lane_worker(start: silly::LaneStart, seed: i64) {
    silly::run_executor_lane<promptnook_native_example::Route>(start, seed,
        promptnook_native_example::initialize, promptnook_native_example::routes,
        promptnook_native_example::handle, lifecycle);
}

thread_fn supervisor(listener: i32, wake: i32, timeout: i64, lanes: i64) {
    var options = promptnook_native_example::options(timeout);
    options.executor.lanes = lanes;
    options.executor.independent_lanes = lanes > 1;
    let result = silly::run_runtime_with_executor(options, silly_transport::Descriptor {
            fd: listener
        },
        silly_transport::Descriptor {
            fd: wake
        }, 0, io_worker, lane_worker);
    assert(qput(RuntimeDone {
            ok: result.ok,
            error: result.error
        }));
}

fn start(timeout: i64 = 10000, lanes: i64 = 1) -> Running {
    qlimit<Started>(4);
    qlimit<Stopped>(4);
    qlimit<HandlerDone>(32);
    qlimit<RuntimeDone>(1);
    var listener = silly_transport::listen("127.0.0.1", 0, 16);
    assert(listener.status == silly_transport::IoStatus.Ready);
    let port = silly_transport::local_port(listener.descriptor);
    assert(port.status == silly_transport::IoStatus.Ready);
    var wake = silly_transport::wake_pair();
    assert(wake.status == silly_transport::IoStatus.Ready);
    let thread = thread_spawn(supervisor, listener.descriptor.fd, wake.reader.fd, timeout, lanes);
    listener.descriptor.fd = -1;
    wake.reader.fd = -1;
    var seen: bool[4] = [false; 4];
    var native_count = 0;
    for index in 2 + lanes {
        let started, present = qget<Started>(10000);
        assert(present);
        let slot = owner_slot(started.owner);
        assert(!seen[slot]);
        seen[slot] = true;
        assert(started.native == started.owner.is_serialized("promptnook_native"));
        if started.native {
            native_count += 1;
            assert(started.owner.lane == 0);
        }
    }
    assert(native_count == 1);
    return Running {
        thread: thread,
        port: port.count as i32,
        wake: wake.writer,
        lanes: lanes
    };
}

fn owner_slot(owner: silly::Owner) -> i64 {
    let slot = if owner.lane < 0 {
        owner.id
    } else {
        owner.lane + 2
    };
    assert(slot >= 0);
    assert(slot < 4);
    return slot;
}

fn request(socket: silly_transport::Descriptor, path: u8[:]) {
    body_socket::send_bytes(socket, connection_socket::request("GET", path));
}

fn health(socket: silly_transport::Descriptor) {
    request(socket, "/health");
    connection_socket::exact(connection_socket::receive(socket), 1, 200, "healthy");
}

fn finish(running: Running&, handlers: i64) {
    assert(silly_transport::notify(running.wake).status == silly_transport::IoStatus.Ready);
    joined(running, handlers);
}

fn io_stopped() {
    var seen: bool[2] = [false; 2];
    for index in 2 {
        let stopped, present = qget<Stopped>(10000);
        assert(present);
        assert(stopped.owner.lane == -1);
        assert(!stopped.native);
        assert(!stopped.opened);
        assert(!seen[stopped.owner.id]);
        seen[stopped.owner.id] = true;
    }
}

fn joined(running: Running&, handlers: i64, io_already_stopped: bool = false, ok: bool = true) {
    let result, present = qget<RuntimeDone>(10000);
    assert(present);
    assert(result.ok == ok);
    assert(result.error == (if ok {
            silly::ServerError.None
        } else {
            silly::ServerError.Hook
        }));
    assert(thread_wait(running.thread));
    var seen: bool[4] = [io_already_stopped, io_already_stopped, false, false];
    var native_count = 0;
    for index in running.lanes + (if io_already_stopped {
            0
        } else {
            2
        }) {
        let stopped,
        found = qpoll<Stopped>();
        assert(found);
        let slot = owner_slot(stopped.owner);
        assert(!seen[slot]);
        seen[slot] = true;
        assert(!stopped.opened);
        if stopped.native {
            native_count += 1;
            assert(stopped.owner.lane == 0);
        }
    }
    assert(native_count == 1);
    let extra, extra_present = qpoll<Stopped>();
    assert(!extra_present);
    var native_handlers = 0;
    for index in 32 {
        let handled, found = qpoll<HandlerDone>();
        if !found {
            break;
        }
        if handled.native {
            native_handlers += 1;
        }
    }
    assert(native_handlers == handlers);
    silly_transport::close(running.wake);
}
