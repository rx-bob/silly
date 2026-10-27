// Method policies are opt-in, scope-local, and produce deterministic bounded Allow values.
namespace route_policy_test;

import silly from "..";

import std;

import.route_test_fixture;

fn define(router: silly::Router<route_test::Action>&) {
    router.get("/default", route_test::Action.Root);
    router.scope("/api") {
        group =>
        group.policy = silly::RoutePolicy {
            head_from_get: true,
            automatic_options: true,
            method_not_allowed: true,
        };
        group.patch("/items/:id", route_test::Action.Update);
        group.get("/items/:id", route_test::Action.Captured);
        group.put("/items/:id", route_test::Action.Update);
        group.get("/items/new", route_test::Action.Static);
        group.head("/explicit", route_test::Action.Static);
        group.get("/explicit", route_test::Action.Captured);
        group.options("/explicit", route_test::Action.Root);
        group.any("/fallback/*path", route_test::Action.Fallback);
        group.get("/fallback/specific", route_test::Action.Static);
        silly::add(group, "ZED", "/custom", route_test::Action.Update);
        silly::add(group, "AAA", "/custom", route_test::Action.Update);
        group.scope("/manual") {
            manual =>
            manual.policy = silly::RoutePolicy {
            };
            manual.get("/item", route_test::Action.Captured);
        };
        group.get("/after", route_test::Action.Static);
    };
    router.get("/outside", route_test::Action.Root);
}

fn allow(plan: silly::RoutePlan<route_test::Action>, path: u8[:], expected: u8[:]) {
    var output: u8[>..] = [];
    assert(silly::route_allow(output, plan, path, expected.len) == silly::ResponseError.None);
    assert(output == expected);
    output.clear();
    output.append("prefix");
    let limit = output.len + expected.len;
    assert(silly::route_allow(output, plan, path, limit - 1) == silly::ResponseError.HeaderBytesLimit);
    assert(output == "prefix");
    assert(silly::route_allow(output, plan, path, limit) == silly::ResponseError.None);
    assert(output == str("prefix", expected));
}

fn verify(plan: silly::RoutePlan<route_test::Action>) {
    assert(plan.issue.error == silly::RouteError.None);
    route_test::missing(plan, "HEAD", "/default");
    route_test::missing(plan, "OPTIONS", "/default");
    route_test::missing(plan, "POST", "/default");
    route_test::selected(plan, "HEAD", "/api/items/new", route_test::Action.Static);
    route_test::selected(plan, "HEAD", "/api/items/123", route_test::Action.Captured);
    route_test::selected(plan, "HEAD", "/api/explicit", route_test::Action.Static);
    route_test::selected(plan, "OPTIONS", "/api/explicit", route_test::Action.Root);
    route_test::selected(plan, "OPTIONS", "/api/fallback/specific", route_test::Action.Fallback);
    route_test::selected(plan, "HEAD", "/api/fallback/specific", route_test::Action.Fallback);
    route_test::selected(plan, "DELETE", "/api/fallback/missing", route_test::Action.Fallback);
    route_test::missing(plan, "HEAD", "/api/manual/item");
    route_test::missing(plan, "OPTIONS", "/api/manual/item");
    route_test::missing(plan, "DELETE", "/api/manual/item");
    route_test::selected(plan, "HEAD", "/api/after", route_test::Action.Static);
    route_test::missing(plan, "HEAD", "/outside");
    route_test::missing(plan, "OPTIONS", "/outside");
    route_test::missing(plan, "POST", "/outside");
    route_test::missing(plan, "OPTIONS", "/unknown");
    route_test::missing(plan, "DELETE", "/api/items/123/extra");
    let generated = silly::match_route(plan, "OPTIONS", "/api/items/123");
    assert(generated.result == silly::RouteMatchResult.GeneratedOptions);
    assert(generated.route_id >= 0);
    let rejected = silly::match_route(plan, "DELETE", "/api/items/123");
    assert(rejected.result == silly::RouteMatchResult.MethodNotAllowed);
    assert(rejected.route_id >= 0);
    assert(silly::match_route(plan, "get", "/api/items/123").result
        == silly::RouteMatchResult.MethodNotAllowed);
    assert(silly::match_route(plan, "BAD METHOD", "/default").result == silly::RouteMatchResult.InvalidMethod);
    assert(silly::match_route(plan, "", "/default").result == silly::RouteMatchResult.InvalidMethod);
    allow(plan, "/api/items/123", "GET, HEAD, OPTIONS, PATCH, PUT");
    allow(plan, "/api/items/new", "GET, HEAD, OPTIONS, PATCH, PUT");
    allow(plan, "/api/explicit", "GET, HEAD, OPTIONS");
    allow(plan, "/api/custom", "AAA, OPTIONS, ZED");
    allow(plan, "/default", "GET");
}

fn invalid_allow(plan: silly::RoutePlan<route_test::Action>) {
    var output: u8[>..] = [];
    output.append("unchanged");
    assert(silly::route_allow(output, plan, "", 100) == silly::ResponseError.InvalidState);
    assert(output == "unchanged");
    assert(silly::route_allow(output, plan, "/default", -1) == silly::ResponseError.InvalidState);
    assert(output == "unchanged");
    var invalid = plan;
    invalid.issue.error = silly::RouteError.InvalidPath;
    assert(silly::route_allow(output, invalid, "/default", 100) == silly::ResponseError.InvalidState);
    assert(output == "unchanged");
}

fn::main() {
    route_test::with_plan(silly::RouteLimits {
        }, route_policy_test::define, route_policy_test::verify);
    route_test::with_plan(silly::RouteLimits {
        }, route_policy_test::define, route_policy_test::invalid_allow);
    print("scoped method policy and bounded Allow passed");
}
