// Prepared static, capture and catch-all dispatch without request-time registration.
namespace route_plan_test;

import silly from "..";

import std;

import.route_test_fixture;

fn define(router: silly::Router<route_test::Action>&) {
    silly::get(router, "/", route_test::Action.Root);
    silly::get(router, "/tree/:id", route_test::Action.Captured);
    silly::get(router, "/tree/new", route_test::Action.Static);
    silly::get(router, "/tree/:id/edit", route_test::Action.Update);
    silly::get(router, "/tree/new/edit", route_test::Action.Static);
    silly::get(router, "/tree/:id/:child", route_test::Action.Captured);
    silly::get(router, "/tree/*path", route_test::Action.CatchAll);
    silly::get(router, "/tree/:id/leaf/end", route_test::Action.Update);
    silly::get(router, "/tree/new/:child/end", route_test::Action.Static);
    silly::any(router, "/portal/*path", route_test::Action.Fallback);
    silly::get(router, "/portal/*path", route_test::Action.CatchAll);
    silly::patch(router, "/tree/:id", route_test::Action.Update);
    silly::scope(router, "/api") {
        api =>
        silly::scope(api, "/workspaces") {
            group =>
            silly::post(group, "", route_test::Action.Root);
            silly::patch(group, "/:workspace_id/collaborators/:email", route_test::Action.Update);
        };
    };
    var local: u8[>..] = [];
    local.append("/local/owned");
    silly::get(router, local, route_test::Action.Static);
    local.clear();
    local.append("/must/not/replace");
}

fn verify(plan: silly::RoutePlan<route_test::Action>) {
    assert(plan.issue.error == silly::RouteError.None);
    assert(plan.entries.len == 15);
    route_test::selected(plan, "GET", "/", route_test::Action.Root);
    route_test::selected(plan, "GET", "/tree/new", route_test::Action.Static);
    route_test::selected(plan, "GET", "/tree/123", route_test::Action.Captured);
    route_test::selected(plan, "GET", "/tree/123/edit", route_test::Action.Update);
    route_test::selected(plan, "GET", "/tree/new/edit", route_test::Action.Static);
    route_test::selected(plan, "GET", "/tree/123/other", route_test::Action.Captured);
    route_test::selected(plan, "GET", "/tree/new/leaf/end", route_test::Action.Static);
    route_test::selected(plan, "GET", "/tree/123/leaf/end", route_test::Action.Update);
    route_test::selected(plan, "GET", "/tree/123/more/than/declared", route_test::Action.CatchAll);
    route_test::selected(plan, "GET", "/portal/nested/file.js", route_test::Action.CatchAll);
    route_test::selected(plan, "POST", "/portal/nested/file.js", route_test::Action.Fallback);
    route_test::selected(plan, "PATCH", "/tree/123", route_test::Action.Update);
    route_test::selected(plan, "POST", "/api/workspaces", route_test::Action.Root);
    route_test::selected(plan, "PATCH", "/api/workspaces/w/collaborators/a+b@example.test", route_test::Action.Update);
    route_test::selected(plan, "GET", "/local/owned", route_test::Action.Static);
    route_test::selected(plan, "GET", "http://example.test/tree/new?x=1", route_test::Action.Static);
    route_test::selected(plan, "GET", "HtTpS://[::1]:443/tree/123", route_test::Action.Captured);
    route_test::selected(plan, "GET", "https://example.test?x=1", route_test::Action.Root);
    assert(silly::match_route(plan, "GET", "http://bad:port/tree/new").result == silly::RouteMatchResult.InvalidPath);
    route_test::missing(plan, "PUT", "/tree/123");
    route_test::missing(plan, "GET", "/api/workspaces");
    route_test::missing(plan, "GET", "/treehouse");
    route_test::missing(plan, "GET", "/must/not/replace");
}

fn dispatch<H>(plan: silly::RoutePlan<route_test::Action>, path: u8[:], seen: i64&) {
    let found = silly::match_route(plan, "GET", path);
    assert(found.result == silly::RouteMatchResult.Matched);
    H(seen, plan.entries[found.route_id].action);
}

fn handler(seen: i64&, action: route_test::Action) {
    match action {
        Static => {
            seen += 1;
        },
        Captured => {
            seen += 10;
        },
        CatchAll => {
            seen += 100;
        },
        _ => {
            assert(false);
        },
    }
}

fn verify_dispatch(plan: silly::RoutePlan<route_test::Action>) {
    var seen: i64 = 0;
    dispatch(plan, "/tree/new", seen, handler);
    dispatch(plan, "/tree/123", seen, handler);
    dispatch(plan, "/tree/a/b/c", seen, handler);
    assert(seen == 111);
}

fn define_empty(router: silly::Router<route_test::Action>&) {
}

fn verify_empty(plan: silly::RoutePlan<route_test::Action>) {
    assert(plan.issue.error == silly::RouteError.None);
    assert(plan.entries.len == 0);
    assert(plan.segments.len == 0);
    assert(plan.bytes.len == 0);
    route_test::missing(plan, "GET", "/");
}

fn::main() {
    route_test::with_plan(silly::RouteLimits {
        }, route_plan_test::define, route_plan_test::verify);
    route_test::with_plan(silly::RouteLimits {
        }, route_plan_test::define, route_plan_test::verify_dispatch);
    route_test::with_plan(silly::RouteLimits {
        }, route_plan_test::define_empty, route_plan_test::verify_empty);
    print("prepared route dispatch passed");
}
