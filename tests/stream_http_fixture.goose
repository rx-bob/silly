// Shared streaming upload fixture; all retained producer data is fixed owned state.
namespace stream_http;

import silly from "..";

import std;

struct App {
    handlers: i64 = 0
}
enum Route {
    Echo,
    Limit,
    Early,
    Health,
    Buffered
}
struct State {
    bytes: i64 = 0,
    pieces: i64 = 0,
    failed: bool = false,
    released: bool = false,
    early: bool = false,
}
type Context = silly::Context<App, State>;
struct Started {
    value: bool = true
}
struct Began {
    route: Route
}
struct Released {
    bytes: i64,
    pieces: i64,
    failed: bool,
    cancelled: bool
}
struct Finished {
    data: silly::CompletionData
}
struct Stopped {
    ok: bool
}

fn define(router: silly::Router<Route>&, app: App&) {
    router.post("/echo", Route.Echo, silly::RouteOptions {
            body: silly::BodyMode.Streamed,
            body_bytes_max: 131072,
            ..
        });
    router.post("/limit", Route.Limit, silly::RouteOptions {
            body: silly::BodyMode.Streamed,
            body_bytes_max: 13,
            ..
        });
    router.post("/early", Route.Early, silly::RouteOptions {
            body: silly::BodyMode.Streamed,
            body_bytes_max: 131072,
            ..
        });
    router.get("/health", Route.Health);
    router.post("/buffered", Route.Buffered, silly::RouteOptions {
            body: silly::BodyMode.Streamed,
            ..
        });
}

fn handle(ctx: Context&, route: Route) {
    ctx.app.handlers += 1;
    if route == Route.Health || route == Route.Buffered {
        ctx.text(200, "ok");
        return;
    }
    assert(ctx.request.body_state == silly::RequestBody.Streamed);
    assert(silly::stream_input(ctx, 200, State {
            early: route == Route.Early,
            ..
        },
        silly::StreamOptions {
            pending_bytes_max: 17,
            ..
        }) == silly::ResponseError.None);
    assert(qput(Began {
            route: route
        }));
}

fn release(state: State&, cancelled: bool) {
    assert(!state.released);
    state.released = true;
    assert(qput(Released {
            bytes: state.bytes,
            pieces: state.pieces,
            failed: state.failed,
            cancelled: cancelled
        }));
}

fn step(state: State&, event: silly::StreamEvent, out: silly::ChunkWriter&) -> silly::StreamStep {
    match event {
        Cancelled => {
            release(state, true);
            return silly::StreamStep.Done;
        },
        Input data => {
            assert(data.bytes.len > 0);
            assert(data.bytes.len <= 17);
            state.bytes += data.bytes.len;
            state.pieces += 1;
            assert(silly::append(out, data.bytes));
            return silly::StreamStep.Chunk {
                flush: false,
                next: silly::Wake.Input
            };
        },
        InputEnd => {
            release(state, false);
            return silly::StreamStep.Done;
        },
        InputFailed error => {
            state.failed = true;
            return silly::StreamStep.Failed {
                reason: error.reason
            };
        },
        Ready => {
            if state.early {
                release(state, false);
                return silly::StreamStep.Done;
            }
            return silly::StreamStep.Wait {
                wake: silly::Wake.Input
            };
        },
    }
}

fn lifecycle(app: App&, event: silly::Lifecycle<Route>) -> silly::HookResult {
    match event {
        Start _ => {
            assert(qput(Started {
                }));
        },
        TransferFinished done => {
            assert(qput(Finished {
                    data: done.completion.data
                }));
        },
        _ => {
        },
    }
    return silly::HookResult.Ok;
}

fn options(body_ms: i64) -> silly::ServerOptions {
    return silly::ServerOptions {
        limits: silly::Limits {
            body_bytes_max: 32,
            output_bytes_max: 32,
            ..
        },
        connections_max: 2,
        response_head_bytes_max: 512,
        buffer_bytes_max: 128 * 1024,
        work_bytes_per_turn: 31,
        accepts_per_turn: 2,
        dispatches_per_turn: 2,
        idle_timeout_ms: 30000,
        body_timeout_ms: body_ms,
        poll_timeout_ms: 10,
        body_limits: silly::BodyLimits {
            bytes_max: 131072,
            ..
        },
        body_read_bytes_max: 31,
        ..
    };
}

thread_fn serve(listener: i32, wake: i32, body_ms: i64) {
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
    let plan = silly::prepare(router);
    assert(plan.issue.error == silly::RouteError.None);
    let result = silly::run_prepared_stream_server<Route, App, State>(options(body_ms),
        silly_transport::Descriptor {
            fd: listener
        }, silly_transport::Descriptor {
            fd: wake
        },
        plan, app, handle, step, lifecycle);
    assert(qput(Stopped {
            ok: result.ok
        }));
}
