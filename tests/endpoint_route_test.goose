// A routed child context cannot overwrite the parent's mount/capture view on guard exit.
namespace endpoint_route_test;

import silly from "..";

import std;

struct App {
    cleanups: i64 = 0,
    reached: bool = false,
}
type Context = silly::Context<App, silly::NoStream>;
enum Route {
    Success,
    Reject,
    Cancel,
    Fallback
}

fn define(router: silly::Router<Route>&) {
    router.scope("/mounted/:tenant") {
        group =>
        group.get("/ok/:id", Route.Success);
        group.get("/reject/:id", Route.Reject);
        group.get("/cancel/:id", Route.Cancel);
        group.any("/*rest", Route.Fallback);
    };
}

fn guard_route(ctx: Context&) {
    assert(ctx.param("tenant").value == "t");
    assert(ctx.param("id").value == "x");
    silly::reject_empty(ctx, 403);
}

fn handle(ctx: Context&, route: Route) {
    assert(ctx.param("tenant").value == "t");
    match route {
        Success => {
            silly::respond_empty(ctx, 204);
        },
        Reject => {
            guard_route(ctx);
            ctx.app.reached = true;
        },
        Cancel => {
            silly::cancel_response(ctx.response, silly::ResponseError.Application);
            silly::reject(ctx);
            ctx.app.reached = true;
        },
        Fallback => {
            assert(ctx.param("rest").value == "unknown/a");
            silly::reject_text(ctx, 404, "domain missing");
            ctx.app.reached = true;
        },
    }
}

fn cleanup(app: App&, outcome: silly::HandlerOutcome) {
    assert(!app.reached);
    assert(app.cleanups == 0);
    app.cleanups += 1;
}

fn check(plan: silly::RoutePlan<Route>, path: u8[:], status: i32) {
    let request = silly::Request {
        method: "GET",
        target: path,
        ..
    };
    var fields: silly::HeaderField[>..] = [];
    var headers: u8[>..] = [];
    var output: u8[>..] = [];
    var response = silly::Response {
        header_fields: fields,
        header_bytes: headers,
        output: output,
        ..
    };
    var app = App {
    };
    // Parent carries a different retained capture view, proving it survives child dispatch.
    let parent = silly::route_captures(plan, 0, "/mounted/parent/ok/original");
    var ctx = Context {
        request: request,
        response: response,
        app: app,
        route_captures: parent,
        ..
    };
    var routes = plan;
    silly::dispatch_route_with_cleanup(routes, ctx, handle, cleanup);
    assert(app.cleanups == 1);
    assert(!app.reached);
    assert(ctx.param("tenant").value == "parent");
    assert(ctx.param("id").value == "original");
    assert(response.status == status);
    if status == 0 {
        assert(response.phase == silly::ResponsePhase.Cancelled);
    } else {
        assert(response.phase == silly::ResponsePhase.Prepared);
    }
}

fn run() {
    var entries: silly::RouteEntry<Route>[>..] = [];
    var segments: silly::RouteSegment[>..] = [];
    var bytes: u8[>..] = [];
    var router = silly::Router<Route> {
        entries: entries,
        segments: segments,
        bytes: bytes,
        ..
    };
    define(router);
    let plan = silly::prepare(router);
    assert(plan.issue.error == silly::RouteError.None);
    check(plan, "/mounted/t/ok/x", 204);
    check(plan, "/mounted/t/reject/x", 403);
    check(plan, "/mounted/t/cancel/x", 0);
    check(plan, "/mounted/t/unknown/a", 404);
    print("endpoint route restoration passed");
}

fn::main() {
    endpoint_route_test::run();
}
