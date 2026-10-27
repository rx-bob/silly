// Finite SSE source. Replay and history remain application policy, not a framework service.
namespace events_example;

import silly from "..";

import std;

struct State {
    last_event_id: u8[..128] = [],
    next: i64 = 0,
    remaining: i64 = 5,
    initial: bool = true,
    heartbeat: bool = false,
    closed: bool = false,
}
type Context = silly::Context<silly::NoState, State>;
enum Route {
    Events
}

fn routes(router: silly::Router<Route>&, app: silly::NoState&) {
    router.get("/events", Route.Events);
}

fn handle(ctx: Context&, route: Route) {
    let previous = ctx.header("Last-Event-ID");
    var state = State {
    };
    if previous.present {
        if previous.value.len > state.last_event_id.cap {
            ctx.text(400, "Last-Event-ID exceeds example limit");
            return;
        }
        state.last_event_id.append(previous.value);
    }
    // Headers are copied; no request view survives the handler. This example does not replay.
    let result = ctx.events(state, silly::SseOptions {
            pending_bytes_max: 512,
            cache_control: "no-cache",
            ..
        });
    if result != silly::ResponseError.None {
        print("SSE selection failed");
    }
}

fn cleanup(state: State&, cancelled: bool) {
    assert(!state.closed);
    state.closed = true;
    state.last_event_id.clear();
    state.remaining = 0;
    print(if cancelled {
            "event source cancelled"
        } else {
            "event source finished"
        });
}

fn frame(state: State&, out: silly::ChunkWriter&) -> bool {
    if state.initial {
        state.initial = false;
        return silly::sse_comment(out, str("connected; last event id: ", state.last_event_id));
    }
    if state.heartbeat {
        state.heartbeat = false;
        return silly::sse_comment(out, "heartbeat");
    }
    let value = str(state.next);
    let written = silly::sse_event(out, silly::SseEvent {
            event: "tick",
            id: value,
            data: value,
            retry_ms: 1000,
            ..
        });
    if written {
        state.next += 1;
        state.remaining -= 1;
        state.heartbeat = true;
    }
    return written;
}

fn step(state: State&, event: silly::StreamEvent, out: silly::ChunkWriter&) -> silly::StreamStep {
    if event == silly::StreamEvent.Cancelled {
        cleanup(state, true);
        return silly::StreamStep.Done;
    }
    assert(event == silly::StreamEvent.Ready);
    if state.remaining == 0 {
        cleanup(state, false);
        return silly::StreamStep.Done;
    }
    if !frame(state, out) {
        return silly::StreamStep.Failed {
            reason: silly::StreamError.OutputLimit
        };
    }
    return silly::StreamStep.Chunk {
        flush: true,
        next: silly::Wake.After {
            delay_ms: 500
        },
    };
}

fn lifecycle(app: silly::NoState&, event: silly::Lifecycle<Route>) -> silly::HookResult {
    return silly::HookResult.Ok;
}

fn run(port: i32) -> silly::ServerResult {
    var app = silly::NoState {
    };
    return silly::serve<Route, silly::NoState, State>(silly::ServerOptions {
            port: port,
            limits: silly::Limits {
                body_bytes_max: 0,
                output_bytes_max: 512,
                ..
            },
            ..
        }, app, routes, handle, step, lifecycle);
}
