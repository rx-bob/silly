// Incremental upload/download with independent decoded-input and pending-output limits.
// No complete request or response body is materialized.
// The owner invokes step only when requested input/output capacity exists.
namespace request_stream_reference;

import silly from "..";

import std;

struct EchoState {
    received_bytes: i64 = 0,
}

type Context = silly::Context<silly::NoState, EchoState>;

enum Route {
    Echo,
}

fn routes(router: silly::Router<Route>&, app: silly::NoState&) {
    router.post("/echo", Route.Echo, silly::RouteOptions {
            body: silly::BodyMode.Streamed,
            body_bytes_max: 8 * 1024 * 1024,
            ..
        });
}

fn handle(ctx: Context&, route: Route) {
    match route {
        Echo => {
            ctx.stream_input(200, EchoState {
                }, silly::StreamOptions {
                    content_type: "application/octet-stream",
                    pending_bytes_max: 1024,
                    ..
                });
        },
    }
}

fn step(state: EchoState&, event: silly::StreamEvent, out: silly::ChunkWriter&) -> silly::StreamStep {
    match event {
        Ready => {
            return silly::StreamStep.Wait {
                wake: silly::Wake.Input,
            };
        },
        Input chunk => {
            if !silly::append(out, chunk.bytes) {
                return silly::StreamStep.Failed {
                    reason: silly::StreamError.OutputLimit,
                };
            }
            state.received_bytes += chunk.bytes.len;
            return silly::StreamStep.Chunk {
                flush: false,
                next: silly::Wake.Input,
            };
        },
        InputEnd => {
            return silly::StreamStep.Done;
        },
        InputFailed error => {
            return silly::StreamStep.Failed {
                reason: error.reason,
            };
        },
        Cancelled => {
            return silly::StreamStep.Done;
        },
    }
}

fn lifecycle(app: silly::NoState&, event: silly::Lifecycle<Route>) -> silly::HookResult {
    return silly::HookResult.Ok;
}

fn::main() {
    let options = silly::ServerOptions {
        address: "127.0.0.1",
        port: 8084,
        limits: silly::Limits {
            body_bytes_max: 0,
            output_bytes_max: 1024,
            ..
        },
        body_limits: silly::BodyLimits {
            bytes_max: 8 * 1024 * 1024,
            ..
        },
        body_read_bytes_max: 1024,
        ..
    };
    var app = silly::NoState {
    };
    let result = silly::serve<request_stream_reference::Route, silly::NoState, request_stream_reference::EchoState>(
        options, app, request_stream_reference::routes, request_stream_reference::handle,
        request_stream_reference::step, request_stream_reference::lifecycle
    );
    if !result.ok {
        print(result.message);
        exit(1);
    }
}
