// Invalid worker-local routes still release initializer-created native resources through Stop.
namespace runtime_startup_test;

import silly from "../../";

import std;

enum Route {
    Value
}

struct App {
    owner: i64,
    socket: silly_transport::Descriptor,
    fail_stop: bool,
    stops: i64 = 0,
}

struct ResourcePeer {
    owner: i64,
    fd: i32,
}

struct Stopped {
    owner: i64,
    count: i64,
}

fn initialize(fail_stop: bool, owner: silly::Owner) -> App {
    var pair = silly_transport::wake_pair();
    assert(pair.status == silly_transport::IoStatus.Ready);
    assert(qput(ResourcePeer {
            owner: owner.id,
            fd: pair.writer.fd,
        }));
    pair.writer.fd = -1;
    return App {
        owner: owner.id,
        socket: pair.reader,
        fail_stop: fail_stop,
        ..
    };
}

fn define(router: silly::Router<Route>&, app: App&) {
    router.get("/same", Route.Value);
    router.get("/same", Route.Value);
}

fn handle(ctx: silly::Context<App, silly::NoStream> & , route: Route) {
    abort("invalid route plan reached endpoint");
}

fn lifecycle(app: App&, event: silly::Lifecycle<Route>) -> silly::HookResult {
    match event {
        Stop stop => {
            assert(stop.owner.id == app.owner);
            assert(app.stops == 0);
            assert(silly_transport::close(app.socket).status == silly_transport::IoStatus.Ready);
            app.stops += 1;
            assert(qput(Stopped {
                    owner: app.owner,
                    count: app.stops,
                }));
        },
        _ => {
            abort("invalid route plan emitted an event other than Stop");
        },
    }
    if app.fail_stop {
        return silly::HookResult.Failed {
            message: "cleanup hook failed after resource release"
        };
    }
    return silly::HookResult.Ok;
}

thread_fn worker(start: silly::WorkerStart, fail_stop: bool) {
    silly::run_runtime_worker<Route>(start, fail_stop, initialize, define, handle, lifecycle);
}

fn verify_released() {
    var owners: bool[2] = [false; 2];
    for index in 2 {
        let stopped, present = qget<Stopped>(10000);
        assert(present);
        assert(stopped.owner >= 0);
        assert(stopped.owner < 2);
        assert(!owners[stopped.owner]);
        owners[stopped.owner] = true;
        assert(stopped.count == 1);
    }
    for index in 2 {
        let peer, present = qget<ResourcePeer>(10000);
        assert(present);
        assert(owners[peer.owner]);
        owners[peer.owner] = false;
        var socket = silly_transport::Descriptor {
            fd: peer.fd
        };
        var bytes: u8[1] = [0];
        assert(silly_transport::read(socket, bytes).status == silly_transport::IoStatus.Closed);
        silly_transport::close(socket);
    }
    let extra, remains = qpoll<Stopped>();
    assert(!remains);
}

fn run(fail_stop: bool) {
    qlimit<ResourcePeer>(2);
    qlimit<Stopped>(2);
    var listener = silly_transport::listen("127.0.0.1", 0, 4);
    assert(listener.status == silly_transport::IoStatus.Ready);
    var wake = silly_transport::wake_pair();
    assert(wake.status == silly_transport::IoStatus.Ready);
    let options = silly::RuntimeOptions {
        workers: 2,
        accept_queue_max: 2,
        worker: silly::WorkerOptions {
            connections_max: 2,
            accepts_per_turn: 2,
            ..
        },
        ..
    };
    assert(silly::valid_runtime_options(options));
    let result = silly::run_runtime(options, listener.descriptor, wake.reader, fail_stop, worker);
    listener.descriptor.fd = -1;
    wake.reader.fd = -1;
    assert(!result.ok);
    assert(result.error == silly::ServerError.Routes);
    assert(result.route_issue.error == silly::RouteError.DuplicateRoute);
    assert((result.hook_failure != silly::HookResult.Ok) == fail_stop);
    verify_released();
    silly_transport::close(wake.writer);
}

fn::main() {
    runtime_startup_test::run(false);
    runtime_startup_test::run(true);
    print("invalid worker routes release initializer resources exactly once");
}
