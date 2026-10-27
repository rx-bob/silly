// Typed startup callbacks and stateful adapters compile without lifecycle scaffolding.
namespace typed_state_test;

import silly from "..";

import std;

struct App {
    definitions: i64 = 0,
    handlers: i64 = 0,
    cleanups: i64 = 0,
}
type Context = silly::Context<App, silly::NoStream>;
enum Route {
    Read
}

fn invalid_routes(router: silly::Router<Route>&, app: App&) {
    app.definitions += 1;
    router.get("/same", Route.Read);
    router.get("/same", Route.Read);
}

fn handle(ctx: Context&, route: Route) {
    ctx.app.handlers += 1;
    silly::reject_empty(ctx, 401);
}

fn cleanup(app: App&, outcome: silly::HandlerOutcome) {
    app.cleanups += 1;
}

fn render(response: silly::Response&, failure: silly::ResponseFailure) {
    silly::default_response_error(response, failure);
}

fn routes_failed(result: silly::ServerResult) {
    assert(!result.ok);
    assert(result.error == silly::ServerError.Routes);
    assert(result.route_issue.error == silly::RouteError.DuplicateRoute);
    assert(result.route_issue.route_id == 1);
    assert(result.route_issue.conflicting_route_id == 0);
}

fn verify_startup(app: App&) {
    let options = silly::ServerOptions {
    };
    routes_failed(silly::serve<Route, App>(options, app, invalid_routes, handle));
    routes_failed(silly::serve_with_cleanup<Route, App>(options, app, invalid_routes, handle, cleanup));
    routes_failed(silly::serve_with_errors<Route, App>(options, app, invalid_routes, handle, render));
    routes_failed(silly::serve_with_cleanup_and_errors<Route, App>(options, app,
        invalid_routes, handle, cleanup, render));
    assert(app.definitions == 4);
    assert(app.handlers == 0);
    assert(app.cleanups == 0);
}

fn invalid_options(result: silly::ServerResult) {
    assert(!result.ok);
    assert(result.error == silly::ServerError.InvalidOptions);
}

fn verify_prepared(app: App&, plan: silly::RoutePlan<Route>) {
    let options = silly::ServerOptions {
        connections_max: 0,
        ..
    };
    invalid_options(silly::serve_prepared(options, plan, app, handle));
    invalid_options(silly::serve_prepared_with_cleanup(options, plan, app, handle, cleanup));
    invalid_options(silly::serve_prepared_with_errors(options, plan, app, handle, render));
    invalid_options(silly::serve_prepared_with_cleanup_and_errors(options, plan, app, handle, cleanup, render));
    let closed = silly_transport::Descriptor {
    };
    invalid_options(silly::run_prepared_server(options, closed, closed, plan, app, handle));
    invalid_options(silly::run_prepared_server_with_cleanup(options, closed, closed, plan, app, handle, cleanup));
    invalid_options(silly::run_prepared_server_with_errors(options, closed, closed, plan, app, handle, render));
    invalid_options(silly::run_prepared_server_with_cleanup_and_errors(options, closed, closed,
        plan, app, handle, cleanup, render));
    assert(app.handlers == 0);
    assert(app.cleanups == 0);
}

fn run() {
    var app = App {
    };
    verify_startup(app);
    var entries: silly::RouteEntry<Route>[>..] = [];
    var segments: silly::RouteSegment[>..] = [];
    var bytes: u8[>..] = [];
    var router = silly::Router<Route> {
        entries: entries,
        segments: segments,
        bytes: bytes,
        ..
    };
    router.get("/read", Route.Read);
    let plan = silly::prepare(router);
    assert(plan.issue.error == silly::RouteError.None);
    verify_prepared(app, plan);
    print("typed state startup and adapter contracts passed");
}

fn::main() {
    typed_state_test::run();
}
