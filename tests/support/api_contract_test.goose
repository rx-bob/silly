// Executable compiler contract for target serve overloads; no production server is mocked.
namespace api_contract_test;

import silly from "../../";

import std;

import.api_contract_fixture;

enum Route {
    Health,
    Events,
}

struct App {
    handled: i64 = 0,
    phase: i64 = 0,
}

struct StreamState {
    prefix: u8[..16] = [],
    calls: i64 = 0,
}

type BasicContext = silly::Context<silly::NoState, silly::NoStream>;
type AppContext = silly::Context<App, silly::NoStream>;
type StreamContext = silly::Context<App, StreamState>;

fn basic_routes(router: api_contract::Router<Route>&) {
    api_contract::get(router, "/health", Route.Health);
}

fn app_routes(router: api_contract::Router<Route>&, app: App&) {
    assert(app.handled == 0);
    api_contract::get(router, "/health", Route.Health);
}

fn stream_routes(router: api_contract::Router<Route>&, app: App&) {
    assert(app.handled == 0);
    api_contract::get(router, "/events", Route.Events);
}

fn reply(response: silly::Response&) {
    assert(silly::begin_response(response, 200) == silly::ResponseError.None);
    assert(silly::append_body(response, "ok") == silly::ResponseError.None);
    assert(silly::prepare_response(response) == silly::ResponseError.None);
}

fn basic_handle(ctx: BasicContext&, route: Route) {
    assert(route == Route.Health);
    assert(ctx.request.target == "/health");
    assert(silly::start_stream(ctx, 200, silly::NoStream {
        }) == silly::ResponseError.InvalidState);
    assert(ctx.response.phase == silly::ResponsePhase.Empty);
    reply(ctx.response);
}

fn app_handle(ctx: AppContext&, route: Route) {
    assert(route == Route.Health);
    ctx.app.handled += 1;
    reply(ctx.response);
}

fn stream_handle(ctx: StreamContext&, route: Route) {
    assert(route == Route.Events);
    ctx.app.handled += 1;
    var state = StreamState {
    };
    state.prefix.append("owned:");
    assert(silly::start_stream(ctx, 200, state) == silly::ResponseError.None);
    state.prefix.clear();
    assert(silly::start_stream(ctx, 201, state) == silly::ResponseError.AlreadyStarted);
    assert(ctx.response.status == 200);
    assert(ctx.response.mode == silly::ResponseBodyMode.Stream);
    var wire: u8[>..] = [];
    assert(silly::write_response_head(wire, ctx.response, 1, 1024) == silly::ResponseError.InvalidState);
    assert(wire.len == 0);
    // The scheduler gets its own fixed-size state value, not a pointer to this local.
}

fn step(state: StreamState&, event: silly::StreamEvent, out: silly::ChunkWriter&) -> silly::StreamStep {
    state.calls += 1;
    match event {
        Ready => {
            assert(state.calls == 1);
            return silly::StreamStep.Wait {
                wake: silly::Wake.After {
                    delay_ms: 5
                }
            };
        },
        Input input => {
            assert(state.calls == 2);
            assert(silly::append(out, state.prefix));
            assert(silly::append(out, input.bytes));
            return silly::StreamStep.Chunk {
                flush: true,
                next: silly::Wake.Input
            };
        },
        InputEnd => {
            assert(state.calls == 3);
            return silly::StreamStep.Done;
        },
        InputFailed failure => {
            assert(state.calls == 3);
            return silly::StreamStep.Failed {
                reason: failure.reason
            };
        },
        Cancelled => {
            assert(state.calls == 3);
            return silly::StreamStep.Done;
        },
    }
}

fn lifecycle(app: App&, event: api_contract::Lifecycle<Route>) -> api_contract::HookResult {
    match event {
        Start start => {
            assert(start.owner.id == 0);
            assert(app.phase == 0);
            app.phase = 1;
        },
        HandlerFinished done => {
            assert(app.phase == 1);
            assert(app.handled == 1);
            assert(done.completion.status == 200);
            app.phase = 2;
        },
        TransferFinished done => {
            assert(app.phase == 2);
            assert(done.completion.route == Route.Health || done.completion.route == Route.Events);
            app.phase = 3;
        },
        Stop stop => {
            assert(stop.owner.id == 0);
            assert(app.phase == 3);
            app.phase = 4;
        },
    }
    return api_contract::HookResult.Ok;
}

fn run() {
    let options = silly::ServerOptions {
    };
    assert(api_contract::serve<Route>(options, basic_routes, basic_handle).ok);
    var app = App {
    };
    assert(api_contract::serve<Route, App>(options, app, app_routes, app_handle, lifecycle).ok);
    assert(app.handled == 0);
    assert(app.phase == 0);
    let streamed = api_contract::serve<Route, App, StreamState>(
        options, app, stream_routes, stream_handle, step, lifecycle
    );
    assert(streamed.ok);
    assert(app.handled == 0);
    assert(app.phase == 0);
}

fn::main() {
    api_contract_test::run();
    print("static API callback contracts passed");
}
