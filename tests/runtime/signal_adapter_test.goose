// Signal delivery is confined to fresh exec children by the native test harness.
namespace signal_adapter_test;

import silly from "../../";

import std;

extern fn silly_signal_test_mode() -> i32;

extern fn silly_signal_test_previous() -> i32;

extern fn silly_signal_test_raise(mode: i32) -> i32;

extern fn silly_signal_test_prior_count() -> i32;

extern fn silly_signal_test_child(mode: i32) -> i32;

extern fn silly_signal_test_conflict() -> i32;

extern fn silly_signal_test_repair() -> i32;

fn child(mode: i32) {
    assert(silly_signal_test_previous() == 0);
    assert(silly_signal_test_raise(mode) == 0);
    assert(silly_signal_test_prior_count() == 1);
    var adapter = silly::install_shutdown_signals();
    assert(adapter.ok);
    assert(adapter.token > 0);
    assert(adapter.error == 0);
    assert(!silly::shutdown_signal_requested(adapter.token));
    var duplicate = silly::install_shutdown_signals();
    assert(!duplicate.ok);
    assert(duplicate.error != 0);
    assert(!silly::uninstall_shutdown_signals(duplicate));
    actual_runtime(adapter.token, mode);
    assert(silly::shutdown_signal_requested(adapter.token));
    assert(silly_signal_test_prior_count() == 1);
    var stale = adapter;
    assert(silly::uninstall_shutdown_signals(adapter));
    assert(!adapter.ok);
    assert(adapter.token == 0);
    assert(!silly::shutdown_signal_requested(stale.token));
    assert(silly_signal_test_raise(mode) == 0);
    assert(silly_signal_test_prior_count() == 2);
    var next = silly::install_shutdown_signals();
    assert(next.ok);
    assert(next.token > stale.token);
    assert(!silly::shutdown_signal_requested(next.token));
    assert(!silly::uninstall_shutdown_signals(stale));
    assert(silly_signal_test_raise(mode) == 0);
    assert(silly::shutdown_signal_requested(next.token));
    assert(!silly::shutdown_signal_requested(stale.token));
    assert(silly::uninstall_shutdown_signals(next));
    assert(silly_signal_test_raise(mode) == 0);
    assert(silly_signal_test_prior_count() == 3);
    conflicting_handler();
}

fn conflicting_handler() {
    var adapter = silly::install_shutdown_signals();
    assert(adapter.ok);
    assert(silly_signal_test_conflict() == 0);
    assert(!silly::uninstall_shutdown_signals(adapter));
    assert(adapter.error != 0);
    assert(silly_signal_test_raise(2) == 0);
    assert(silly_signal_test_prior_count() == 4);
    assert(!silly::shutdown_signal_requested(adapter.token));
    assert(silly_signal_test_raise(1) == 0);
    assert(silly::shutdown_signal_requested(adapter.token));
    assert(silly_signal_test_prior_count() == 4);
    assert(silly_signal_test_repair() == 0);
    assert(silly::uninstall_shutdown_signals(adapter));
}

enum Route {
    Probe
}
struct Started {
    owner: i64
}
struct Stopped {
    owner: i64
}
struct RuntimeDone {
    ok: bool,
    drain: silly::DrainStatus
}

fn initialize(seed: i64, owner: silly::Owner) -> silly::NoState {
    return silly::NoState {
    };
}

fn define(router: silly::Router<Route>&, app: silly::NoState&) {
    router.get("/", Route.Probe);
}

fn handle(ctx: silly::Context<silly::NoState, silly::NoStream> & , route: Route) {
    ctx.text(200, "ready");
}

fn lifecycle(app: silly::NoState&, event: silly::Lifecycle<Route>) -> silly::HookResult {
    match event {
        Start start => {
            assert(qput(Started {
                    owner: start.owner.id
                }));
        },
        Stop stop => {
            assert(qput(Stopped {
                    owner: stop.owner.id
                }));
        },
        _ => {
        },
    }
    return silly::HookResult.Ok;
}

thread_fn worker(start: silly::WorkerStart, seed: i64) {
    silly::run_runtime_worker<Route>(start, seed, initialize, define, handle, lifecycle);
}

thread_fn supervisor(listener: i32, wake: i32, token: i64) {
    let options = silly::RuntimeOptions {
        signal_token: token,
        worker: silly::WorkerOptions {
            limits: silly::Limits {
                body_bytes_max: 1024,
                output_bytes_max: 1024,
                ..
            },
            ..
        },
        ..
    };
    let result = silly::run_runtime(options, silly_transport::Descriptor {
            fd: listener
        },
        silly_transport::Descriptor {
            fd: wake
        }, 0, worker);
    assert(qput(RuntimeDone {
            ok: result.ok,
            drain: result.drain
        }));
}

fn actual_runtime(token: i64, mode: i32) {
    qlimit<Started>(1);
    qlimit<Stopped>(1);
    qlimit<RuntimeDone>(1);
    var listener = silly_transport::listen("127.0.0.1", 0, 4);
    assert(listener.status == silly_transport::IoStatus.Ready);
    var wake = silly_transport::wake_pair();
    assert(wake.status == silly_transport::IoStatus.Ready);
    let listener_fd = listener.descriptor.fd;
    let thread = thread_spawn(supervisor, listener_fd, wake.reader.fd, token);
    listener.descriptor.fd = -1;
    wake.reader.fd = -1;
    let started, present = qget<Started>(10000);
    assert(present);
    assert(started.owner == 0);
    assert(silly_signal_test_raise(mode) == 0);
    let done, finished = qget<RuntimeDone>(10000);
    assert(finished);
    assert(done.ok);
    assert(done.drain == silly::DrainStatus.Complete);
    assert(thread_wait(thread));
    let stopped, released = qpoll<Stopped>();
    assert(released);
    assert(stopped.owner == 0);
    let extra, repeated = qpoll<Stopped>();
    assert(!repeated);
    assert(silly_transport::local_port(silly_transport::Descriptor {
            fd: listener_fd
        }).status
        != silly_transport::IoStatus.Ready);
    var bytes: u8[1] = [0];
    assert(silly_transport::read(wake.writer, bytes).status == silly_transport::IoStatus.Closed);
    silly_transport::close(wake.writer);
}

fn::main() {
    let mode = signal_adapter_test::silly_signal_test_mode();
    if mode != 0 {
        signal_adapter_test::child(mode);
    } else {
        assert(signal_adapter_test::silly_signal_test_child(1) == 0);
        assert(signal_adapter_test::silly_signal_test_child(2) == 0);
        print("isolated SIGINT/SIGTERM installation, request and restoration passed");
    }
}
