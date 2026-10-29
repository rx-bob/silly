// An unknown named lane fails startup before any app Start or endpoint callback.
namespace serialized_startup_test;

import silly from "../../";

import std;

enum Route {
    Native
}

struct App {
    owner: silly::Owner,
    stopped: bool = false,
}

struct Stopped {
    lane: i64,
}

fn initialize(seed: i64, owner: silly::Owner) -> App {
    assert(seed == 37);
    return App {
        owner: owner,
        ..
    };
}

fn define(router: silly::Router<Route>&, app: App&) {
    router.execution(silly::Execution.Serialized {
            lane: "missing"
        });
    router.get("/native", Route.Native);
}

fn handle(ctx: silly::Context<App, silly::NoStream> & , route: Route) {
    abort("unknown lane reached endpoint");
}

fn lifecycle(app: App&, event: silly::Lifecycle<Route>) -> silly::HookResult {
    match event {
        Stop stop => {
            assert(!app.stopped);
            app.stopped = true;
            assert(stop.owner.lane == app.owner.lane);
            assert(stop.owner.is_serialized("native") == (app.owner.lane == 0));
            assert(!stop.owner.is_serialized("missing"));
            assert(qput(Stopped {
                    lane: app.owner.lane
                }));
        },
        _ => {
            abort("unknown lane emitted an event before startup validation");
        },
    }
    return silly::HookResult.Ok;
}

thread_fn io_worker(start: silly::WorkerStart, seed: i64) {
    silly::run_runtime_worker<Route>(start, seed, initialize, define, handle, lifecycle);
}

thread_fn lane_worker(start: silly::LaneStart, seed: i64) {
    silly::run_executor_lane<Route>(start, seed, initialize, define, handle, lifecycle);
}

fn run() {
    qlimit<Stopped>(2);
    var listener = silly_transport::listen("127.0.0.1", 0, 4);
    assert(listener.status == silly_transport::IoStatus.Ready);
    var wake = silly_transport::wake_pair();
    assert(wake.status == silly_transport::IoStatus.Ready);
    let options = silly::RuntimeOptions {
        executor: silly::ExecutorOptions {
            serialized_name: "native",
            lanes: 1,
            ..
        },
        ..
    };
    assert(silly::valid_runtime_options(options));
    let result = silly::run_runtime_with_executor(options, listener.descriptor, wake.reader, 37,
        io_worker, lane_worker);
    listener.descriptor.fd = -1;
    wake.reader.fd = -1;
    assert(!result.ok);
    assert(result.error == silly::ServerError.Routes);
    let first, has_first = qpoll<Stopped>();
    let second, has_second = qpoll<Stopped>();
    assert(has_first);
    assert(has_second);
    assert(first.lane != second.lane);
    assert(first.lane + second.lane == -1);
    let extra, has_extra = qpoll<Stopped>();
    assert(!has_extra);
    silly_transport::close(wake.writer);
}

fn::main() {
    serialized_startup_test::run();
    print("unknown serialized name rejects startup and stops initialized owners exactly once");
}
