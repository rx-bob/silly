// Inclusive preparation limits and request-side errors never silently match a prefix.
namespace route_plan_limits_test;

import silly from "..";

import std;

import.route_test_fixture;

fn define(router: silly::Router<route_test::Action>&) {
    silly::get(router, "/:id/:leaf", route_test::Action.Captured);
}

fn exact(plan: silly::RoutePlan<route_test::Action>) {
    assert(plan.issue.error == silly::RouteError.None);
    assert(plan.entries.len == 1);
    assert(plan.segments.len == 2);
    assert(plan.bytes.len == 13);
    route_test::selected(plan, "GET", "/abc/defgh", route_test::Action.Captured);
    assert(silly::match_route(plan, "GET", "/abc/defghi").result == silly::RouteMatchResult.PathLimit);
    assert(silly::match_route(plan, "GET", "/a/b/c").result == silly::RouteMatchResult.SegmentLimit);
    assert(silly::match_route(plan, "GET", "abc").result == silly::RouteMatchResult.InvalidPath);
    assert(!silly::route_capture(plan, 0, "/abc/defghi", "id").present);
    assert(!silly::route_capture(plan, 0, "/a/b/c", "id").present);
    assert(!silly::route_capture(plan, 0, "https:///a/b", "id").present);
}

fn raw_captures(plan: silly::RoutePlan<route_test::Action>) {
    let path = "/a%2Fb/x+y";
    let found = silly::match_route(plan, "GET", path);
    assert(found.result == silly::RouteMatchResult.Matched);
    let id = silly::route_capture(plan, found.route_id, path, "id");
    let leaf = silly::route_capture(plan, found.route_id, path, "leaf");
    assert(id.present);
    assert(id.value == "a%2Fb");
    assert(leaf.present);
    assert(leaf.value == "x+y");
    let absolute = "https://example.test/a%2Fb/x+y?ignored=true";
    let absolute_id = silly::route_capture(plan, found.route_id, absolute, "id");
    assert(absolute_id.present);
    assert(absolute_id.value == "a%2Fb");
}

fn catch_all(router: silly::Router<route_test::Action>&) {
    silly::get(router, "/files/*path", route_test::Action.CatchAll);
}

fn catch_all_values(plan: silly::RoutePlan<route_test::Action>) {
    let path = "/files/a/b%2Fc";
    let found = silly::match_route(plan, "GET", path);
    assert(found.result == silly::RouteMatchResult.Matched);
    let value = silly::route_capture(plan, found.route_id, path, "path");
    assert(value.present);
    assert(value.value == "a/b%2Fc");
}

fn::main() {
    let exact = silly::RouteLimits {
        routes_max: 1,
        path_bytes_max: 10,
        segments_max: 2,
        captures_max: 2,
        storage_bytes_max: 13,
        compiled_segments_max: 2,
        method_bytes_max: 3,
    };
    route_test::with_plan(exact, route_plan_limits_test::define, route_plan_limits_test::exact);
    route_test::with_plan(silly::RouteLimits {
        }, route_plan_limits_test::define, route_plan_limits_test::raw_captures);
    route_test::with_plan(silly::RouteLimits {
        }, route_plan_limits_test::catch_all, route_plan_limits_test::catch_all_values);
    print("route limits and raw captures passed");
}
