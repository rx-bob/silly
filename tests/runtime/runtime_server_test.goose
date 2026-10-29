// Real workers own independent app counters, route storage, persistent requests and output slabs.
namespace runtime_server_test;

import silly from "../../";

import std;

import.body_socket_fixture;
import.connection_socket_fixture;

enum Route {
    Count,
    Large
}

struct App {
    owner: i64,
    fail_start: bool = false,
    count: i64 = 0,
    starts: i64 = 0,
    handlers: i64 = 0,
    transfers: i64 = 0,
    stops: i64 = 0,
}

struct Started {
    owner: i64
}

struct Finished {
    app: App
}

struct RuntimeFinished {
    ok: bool,
    error: silly::ServerError
}

struct LargeHandled {
    owner: i64
}

fn initialize(seed: i64, owner: silly::Owner) -> App {
    assert(seed == 17 || seed == 18);
    return App {
        owner: owner.id,
        fail_start: seed == 18,
        ..
    };
}

fn define(router: silly::Router<Route>&, app: App&) {
    assert(app.count == 0);
    router.get("/count", Route.Count);
    router.get("/large", Route.Large);
}

fn handle(ctx: silly::Context<App, silly::NoStream> & , route: Route) {
    ctx.app.count += 1;
    if route == Route.Large {
        assert(qput(LargeHandled {
                owner: ctx.app.owner
            }));
        let bytes: u8[4194304] = ['x'; 4194304];
        ctx.bytes(200, bytes);
    } else {
        ctx.text(200, str(ctx.app.owner, ":", ctx.app.count));
    }
}

fn lifecycle(app: App&, event: silly::Lifecycle<Route>) -> silly::HookResult {
    match event {
        Start start => {
            assert(start.owner.id == app.owner);
            app.starts += 1;
            assert(qput(Started {
                    owner: app.owner
                }));
            if app.fail_start && app.owner == 1 {
                return silly::HookResult.Failed {
                    message: "worker startup failed"
                };
            }
        },
        HandlerFinished done => {
            assert(done.completion.data.handler_ran);
            app.handlers += 1;
        },
        TransferFinished done => {
            assert(done.completion.data.handler_ran);
            assert(done.completion.data.transfer != silly::TransferOutcome.Pending);
            app.transfers += 1;
        },
        Stop stop => {
            assert(stop.owner.id == app.owner);
            app.stops += 1;
            assert(qput(Finished {
                    app: app
                }));
        },
    }
    return silly::HookResult.Ok;
}

thread_fn worker(start: silly::WorkerStart, seed: i64) {
    silly::run_runtime_worker<Route>(start, seed, initialize, define, handle, lifecycle);
}

thread_fn serve(listener: i32, wake: i32, seed: i64, workers: i64) {
    let options = silly::RuntimeOptions {
        workers: workers,
        accept_queue_max: 2,
        connections_max: 64,
        buffer_bytes_max: 128 * 1024 * 1024,
        worker: silly::WorkerOptions {
            limits: silly::Limits {
                head_bytes_max: 1024,
                body_bytes_max: 1024,
                output_bytes_max: 4194304,
                ..
            },
            connections_max: 4,
            response_head_bytes_max: 512,
            buffer_bytes_max: 32 * 1024 * 1024,
            work_bytes_per_turn: 4096,
            accepts_per_turn: 1,
            dispatches_per_turn: 1,
            idle_timeout_ms: 10000,
            poll_timeout_ms: 10,
            ..
        },
    };
    var result = silly::run_runtime(options, silly_transport::Descriptor {
            fd: listener
        }, silly_transport::Descriptor {
            fd: wake
        }, seed, worker);
    if result.drain == silly::DrainStatus.Incomplete {
        var pending = result.pending;
        result = silly::resume_shutdown(pending, 10000);
    }
    assert(qput(RuntimeFinished {
            ok: result.ok,
            error: result.error
        }));
}

fn request(socket: silly_transport::Descriptor, owner: i64, count: i64) {
    body_socket::send_bytes(socket, connection_socket::request("GET", "/count"));
    connection_socket::exact(connection_socket::receive(socket), 1, 200, str(owner, ":", count));
}

fn pipeline(socket: silly_transport::Descriptor, owner: i64) {
    let one = connection_socket::request("GET", "/count");
    body_socket::send_bytes(socket, str(one, one));
    connection_socket::exact(connection_socket::receive(socket), 1, 200, str(owner, ":2"));
    connection_socket::exact(connection_socket::receive(socket), 1, 200, str(owner, ":3"));
}

fn probe(port: i32, owner: i64, count: i64) {
    var socket = body_socket::connect(port);
    body_socket::send_bytes(socket, connection_socket::request("GET", "/count", 1, "Connection: close\r\n"));
    connection_socket::exact(body_socket::receive_closed(socket), 1, 200, str(owner, ":", count));
    silly_transport::close(socket);
}

fn started() {
    let first, has_first = qget<Started>(10000);
    let second, has_second = qget<Started>(10000);
    assert(has_first);
    assert(has_second);
    assert(first.owner != second.owner);
    assert(first.owner + second.owner == 1);
}

fn finished() {
    let first, has_first = qget<Finished>(10000);
    let second, has_second = qget<Finished>(10000);
    assert(has_first);
    assert(has_second);
    assert(first.app.owner != second.app.owner);
    for app in[first.app, second.app] {
        assert(app.starts == 1);
        assert(app.stops == 1);
        assert(app.handlers == app.count);
        assert(app.transfers == app.handlers);
        assert(app.count == 4 + app.owner);
    }
    let done, present = qget<RuntimeFinished>(10000);
    assert(present);
    assert(done.ok);
    assert(done.error == silly::ServerError.None);
    let extra, remains = qpoll<Finished>();
    assert(!remains);
}

fn run() {
    qlimit<Started>(2);
    qlimit<Finished>(2);
    qlimit<RuntimeFinished>(1);
    qlimit<LargeHandled>(1);
    var listener = silly_transport::listen("127.0.0.1", 0, 16);
    assert(listener.status == silly_transport::IoStatus.Ready);
    let port = silly_transport::local_port(listener.descriptor).count as i32;
    var wake = silly_transport::wake_pair();
    assert(wake.status == silly_transport::IoStatus.Ready);
    let supervisor = thread_spawn(serve, listener.descriptor.fd, wake.reader.fd, 17, 2);
    listener.descriptor.fd = -1;
    wake.reader.fd = -1;
    started();
    var first = body_socket::connect(port);
    request(first, 0, 1);
    var second = body_socket::connect(port);
    request(second, 1, 1);
    pipeline(first, 0);
    pipeline(second, 1);
    // Idle and stalled peers occupy each owner; later admitted work still progresses.
    var idle = body_socket::connect(port);
    var stalled = body_socket::connect(port);
    assert(silly_transport::set_receive_buffer(stalled, 1024).status == silly_transport::IoStatus.Ready);
    body_socket::send_bytes(stalled, connection_socket::request("GET", "/large"));
    let large, admitted = qget<LargeHandled>(10000);
    assert(admitted);
    assert(large.owner == 1);
    probe(port, 0, 4);
    probe(port, 1, 5);
    assert(silly_transport::notify(wake.writer).status == silly_transport::IoStatus.Ready);
    finished();
    assert(thread_wait(supervisor));
    silly_transport::close(first);
    silly_transport::close(second);
    silly_transport::close(idle);
    silly_transport::close(stalled);
    silly_transport::close(wake.writer);
}

fn failed_start() {
    qlimit<Started>(2);
    qlimit<Finished>(2);
    qlimit<RuntimeFinished>(1);
    var listener = silly_transport::listen("127.0.0.1", 0, 16);
    assert(listener.status == silly_transport::IoStatus.Ready);
    var wake = silly_transport::wake_pair();
    assert(wake.status == silly_transport::IoStatus.Ready);
    let supervisor = thread_spawn(serve, listener.descriptor.fd, wake.reader.fd, 18, 2);
    listener.descriptor.fd = -1;
    wake.reader.fd = -1;
    started();
    let first, has_first = qget<Finished>(10000);
    let second, has_second = qget<Finished>(10000);
    assert(has_first);
    assert(has_second);
    assert(first.app.owner != second.app.owner);
    for app in[first.app, second.app] {
        assert(app.starts == 1);
        assert(app.stops == 1);
        assert(app.handlers == 0);
        assert(app.transfers == 0);
    }
    let done, present = qget<RuntimeFinished>(10000);
    assert(present);
    assert(!done.ok);
    assert(done.error == silly::ServerError.Hook);
    assert(thread_wait(supervisor));
    silly_transport::close(wake.writer);
}

fn singleton_refusal() {
    var listener = silly_transport::listen("127.0.0.1", 0, 4);
    assert(listener.status == silly_transport::IoStatus.Ready);
    var wake = silly_transport::wake_pair();
    assert(wake.status == silly_transport::IoStatus.Ready);
    let result = silly::run_runtime(silly::RuntimeOptions {
        }, listener.descriptor, wake.reader, 17, worker);
    listener.descriptor.fd = -1;
    wake.reader.fd = -1;
    assert(!result.ok);
    assert(result.error == silly::ServerError.ShutdownBusy);
    assert(result.message == "runtime ownership is retained or poisoned");
    silly_transport::close(wake.writer);
}

fn four_workers() {
    qlimit<Started>(4);
    qlimit<Finished>(4);
    qlimit<RuntimeFinished>(1);
    var listener = silly_transport::listen("127.0.0.1", 0, 16);
    assert(listener.status == silly_transport::IoStatus.Ready);
    let port = silly_transport::local_port(listener.descriptor).count as i32;
    var wake = silly_transport::wake_pair();
    assert(wake.status == silly_transport::IoStatus.Ready);
    let supervisor = thread_spawn(serve, listener.descriptor.fd, wake.reader.fd, 17, 4);
    listener.descriptor.fd = -1;
    wake.reader.fd = -1;
    var owners: bool[4] = [false; 4];
    for index in 4 {
        let event, present = qget<Started>(10000);
        assert(present);
        assert(event.owner >= 0);
        assert(event.owner < 4);
        assert(!owners[event.owner]);
        owners[event.owner] = true;
    }
    singleton_refusal();
    for owner in 4 {
        probe(port, owner, 1);
    }
    assert(silly_transport::notify(wake.writer).status == silly_transport::IoStatus.Ready);
    for index in 4 {
        let event, present = qget<Finished>(10000);
        assert(present);
        assert(owners[event.app.owner]);
        owners[event.app.owner] = false;
        assert(event.app.starts == 1);
        assert(event.app.stops == 1);
        assert(event.app.count == 1);
        assert(event.app.handlers == 1);
        assert(event.app.transfers == 1);
    }
    let done, present = qget<RuntimeFinished>(10000);
    assert(present);
    assert(done.ok);
    assert(thread_wait(supervisor));
    let extra, remains = qpoll<Started>();
    assert(!remains);
    silly_transport::close(wake.writer);
}

fn::main() {
    runtime_server_test::run();
    runtime_server_test::four_workers();
    runtime_server_test::failed_start();
    // Reusing the finite owner set after joins must leave no queued sockets or control messages.
    runtime_server_test::run();
    print("worker isolation, persistence, stalled peers and repeated shutdown passed");
}
