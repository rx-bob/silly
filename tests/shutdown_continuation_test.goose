// Owner Stop cancels retained producer state exactly once, even while waiting for activity.
namespace shutdown_continuation_test;

import silly from "..";

import std;

struct Producer {
    resource: silly_transport::Descriptor = silly_transport::Descriptor {
    },
    cancellations: i64 = 0,
}
struct App {
    producer: silly::Continuation<Producer>,
}
enum Route {
    Empty
}
struct Peer {
    fd: i32
}
struct Finished {
    cancellations: i64
}

fn step(state: Producer&, event: silly::StreamEvent, output: silly::ChunkWriter&) -> silly::StreamStep {
    if event == silly::StreamEvent.Cancelled {
        assert(silly_transport::close(state.resource).status == silly_transport::IoStatus.Ready);
        state.cancellations += 1;
        return silly::StreamStep.Done;
    }
    return silly::StreamStep.Wait {
        wake: silly::Wake.After {
            delay_ms: 10000
        }
    };
}

fn initialize(seed: i64, owner: silly::Owner) -> App {
    var pair = silly_transport::wake_pair();
    assert(pair.status == silly_transport::IoStatus.Ready);
    assert(qput(Peer {
            fd: pair.writer.fd
        }));
    return App {
        producer: silly::Continuation<Producer> {
            key: silly::TransferKey {
                owner: owner.id,
                slot: 0,
                connection_generation: 1,
                request_generation: 1
            },
            state: Producer {
                resource: pair.reader,
                ..
            },
            ..
        }
    };
}

fn define(router: silly::Router<Route>&, app: App&) {
    router.get("/", Route.Empty);
}

fn handle(ctx: silly::Context<App, silly::NoStream> & , route: Route) {
    ctx.text(200, "ok");
}

fn lifecycle(app: App&, event: silly::Lifecycle<Route>) -> silly::HookResult {
    match event {
        Start started => {
            let key = app.producer.key;
            silly::resume(app.producer, key, silly::StreamEvent.Ready, step);
            assert(app.producer.state.cancellations == 0);
        },
        Stop stopped => {
            let key = app.producer.key;
            silly::cancel_continuation(app.producer, key, step);
            silly::cancel_continuation(app.producer, key, step);
            assert(app.producer.terminal_count == 1);
            assert(qput(Finished {
                    cancellations: app.producer.state.cancellations
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

fn::main() {
    qlimit<shutdown_continuation_test::Peer>(1);
    qlimit<shutdown_continuation_test::Finished>(1);
    var listener = silly_transport::listen("127.0.0.1", 0, 4);
    assert(listener.status == silly_transport::IoStatus.Ready);
    var wake = silly_transport::wake_pair();
    assert(wake.status == silly_transport::IoStatus.Ready);
    assert(silly_transport::notify(wake.writer).status == silly_transport::IoStatus.Ready);
    let result = silly::run_runtime(silly::RuntimeOptions {
        }, listener.descriptor, wake.reader,
        0, shutdown_continuation_test::worker);
    assert(result.ok);
    assert(result.drain == silly::DrainStatus.Complete);
    let finished, present = qpoll<shutdown_continuation_test::Finished>();
    assert(present);
    assert(finished.cancellations == 1);
    let peer, owned = qpoll<shutdown_continuation_test::Peer>();
    assert(owned);
    var writer = silly_transport::Descriptor {
        fd: peer.fd
    };
    assert(silly_transport::notify(writer).status == silly_transport::IoStatus.Closed);
    silly_transport::close(writer);
    silly_transport::close(wake.writer);
    print("shutdown cancels retained producer and releases its foreign resource once");
}
