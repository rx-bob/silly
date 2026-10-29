// Missing concrete executors and unavailable route lanes fail before admission.
namespace executor_runtime_startup_test;

import silly from "../../";

import std;

enum Route {
    Work
}
struct App {
    owner: i64
}
struct Stopped {
    owner: i64
}
struct Initialized {
    owner: i64
}

fn initialize(seed: i64, owner: silly::Owner) -> App {
    assert(qput(Initialized {
            owner: owner.id
        }));
    return App {
        owner: owner.id
    };
}

fn define(router: silly::Router<Route>&, app: App&) {
    router.get("/work", Route.Work, silly::RouteOptions {
            execution: silly::ExecutionClass.Lane {
                index: 0
            },
            ..
        });
}

fn handle(ctx: silly::Context<App, silly::NoStream> & , route: Route) {
    abort("unavailable executor reached handler");
}

fn lifecycle(app: App&, event: silly::Lifecycle<Route>) -> silly::HookResult {
    match event {
        Stop stop => {
            assert(stop.owner.id == app.owner);
            assert(qput(Stopped {
                    owner: app.owner
                }));
        },
        _ => {
            abort("unavailable executor emitted lifecycle start");
        },
    }
    return silly::HookResult.Ok;
}

thread_fn worker(start: silly::WorkerStart, seed: i64) {
    silly::run_runtime_worker<Route>(start, seed, initialize, define, handle, lifecycle);
}

fn run(lanes: i64) {
    qlimit<Initialized>(1);
    qlimit<Stopped>(1);
    var listener = silly_transport::listen("127.0.0.1", 0, 4);
    assert(listener.status == silly_transport::IoStatus.Ready);
    var wake = silly_transport::wake_pair();
    assert(wake.status == silly_transport::IoStatus.Ready);
    var options = silly::RuntimeOptions {
    };
    options.executor.lanes = lanes;
    let result = silly::run_runtime(options, listener.descriptor, wake.reader, 0, worker);
    listener.descriptor.fd = -1;
    wake.reader.fd = -1;
    assert(!result.ok);
    if lanes == 0 {
        assert(result.error == silly::ServerError.Routes);
        assert(result.route_issue.error == silly::RouteError.UnsupportedOptions);
        assert(result.route_issue.route_id == 0);
    } else {
        assert(result.error == silly::ServerError.InvalidOptions);
    }
    let initialized, was_initialized = qpoll<Initialized>();
    let stopped, was_stopped = qpoll<Stopped>();
    assert(was_initialized == (lanes == 0));
    assert(was_stopped == (lanes == 0));
    var bytes: u8[1] = [0];
    assert(silly_transport::read(wake.writer, bytes).status == silly_transport::IoStatus.Closed);
    silly_transport::close(wake.writer);
}

fn::main() {
    executor_runtime_startup_test::run(1);
    executor_runtime_startup_test::run(0);
    executor_runtime_startup_test::run(0);
    print("executor runtime startup rejection passed");
}
