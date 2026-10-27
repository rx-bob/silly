// Exact raw routing, movable domain mounts and bounded method policy.
namespace router_test;

import silly from "..";

import std;

import.route_test_fixture;

fn domain(router: silly::Router<route_test::Action>&) {
    router.get("/:workspace/shares/:share", route_test::Action.Captured);
    router.patch("/:workspace/collaborators/:email", route_test::Action.Update);
    router.put("/:workspace/collaborators/:email", route_test::Action.Update);
    router.scope("/:workspace/portal") {
        portal =>
        portal.get("/new", route_test::Action.Static);
        portal.get("/:key", route_test::Action.Captured);
        portal.get("/*path", route_test::Action.CatchAll);
    };
}

fn define(router: silly::Router<route_test::Action>&) {
    router.scope("/api") {
        api =>
        api.scope("/workspaces", domain);
    };
    router.scope("/moved", domain);
    router.get("/outside", route_test::Action.Root);
    router.get("/slashes//literal/", route_test::Action.Static);
    router.get("/slashes/:id", route_test::Action.Captured);
    router.get("/files", route_test::Action.Static);
    router.get("/files/*path", route_test::Action.CatchAll);
    router.get("/raw/:key", route_test::Action.Captured);
}

fn capture(plan: silly::RoutePlan<route_test::Action>, target: u8[:], name: u8[:], value: u8[:]) {
    let found = silly::match_route(plan, "GET", target);
    assert(found.result == silly::RouteMatchResult.Matched);
    let field = silly::route_capture(plan, found.route_id, target, name);
    assert(field.present);
    assert(field.value == value);
    assert(!silly::route_capture(plan, found.route_id, target, "unknown").present);
}

fn moved(plan: silly::RoutePlan<route_test::Action>, prefix: u8[:]) {
    let share = str(prefix, "/w/shares/s");
    route_test::selected(plan, "GET", share, route_test::Action.Captured);
    route_test::missing(plan, "GET", str(share, "/extra"));
    route_test::missing(plan, "GET", str(share, "/"));
    route_test::missing(plan, "GET", str(prefix, "/w/shares/"));
    capture(plan, share, "workspace", "w");
    capture(plan, share, "share", "s");
    let collaborator = str(prefix, "/w/collaborators/a+b%40example.test");
    route_test::selected(plan, "PUT", collaborator, route_test::Action.Update);
    route_test::selected(plan, "PATCH", collaborator, route_test::Action.Update);
    route_test::missing(plan, "POST", collaborator);
    let selected = silly::match_route(plan, "PATCH", collaborator);
    let email = silly::route_capture(plan, selected.route_id, collaborator, "email");
    assert(email.present);
    assert(email.value == "a+b%40example.test");
    route_test::selected(plan, "GET", str(prefix, "/w/portal/new"), route_test::Action.Static);
    route_test::selected(plan, "GET", str(prefix, "/w/portal/key"), route_test::Action.Captured);
    route_test::selected(plan, "GET", str(prefix, "/w/portal/key/file"), route_test::Action.CatchAll);
    capture(plan, str(prefix, "/w/portal/key/file"), "path", "key/file");
}

fn raw(plan: silly::RoutePlan<route_test::Action>) {
    assert(plan.issue.error == silly::RouteError.None);
    moved(plan, "/api/workspaces");
    moved(plan, "/moved");
    route_test::selected(plan, "GET", "/outside", route_test::Action.Root);
    route_test::missing(plan, "GET", "/api/outside");
    route_test::selected(plan, "GET", "/slashes//literal/", route_test::Action.Static);
    route_test::missing(plan, "GET", "/slashes/literal/");
    route_test::missing(plan, "GET", "/slashes//literal");
    route_test::missing(plan, "GET", "/slashes/");
    route_test::missing(plan, "GET", "/slashes//");
    route_test::selected(plan, "GET", "/files", route_test::Action.Static);
    capture(plan, "/files/", "path", "");
    capture(plan, "/files//a///b/", "path", "/a///b/");
    route_test::missing(plan, "GET", "/files-other/a");
    capture(plan, "/raw/a%252Fb?unused=a/b", "key", "a%252Fb");
    capture(plan, "/raw/a%2Fb", "key", "a%2Fb");
    capture(plan, "/raw/a+b@example.test", "key", "a+b@example.test");
    capture(plan, "http://example.test/raw/a%2fb?x=1", "key", "a%2fb");
    route_test::missing(plan, "GET", "/raw/a/b");
    assert(silly::match_route(plan, "GET", "").result == silly::RouteMatchResult.InvalidPath);
    assert(silly::match_route(plan, "GET", "raw/x").result == silly::RouteMatchResult.InvalidPath);
    assert(!silly::route_capture(plan, -1, "/raw/x", "key").present);
    assert(!silly::route_capture(plan, plan.entries.len, "/raw/x", "key").present);
}

fn limited(router: silly::Router<route_test::Action>&) {
    router.get("/:id/*rest", route_test::Action.CatchAll);
}

fn limit_values(plan: silly::RoutePlan<route_test::Action>) {
    assert(plan.issue.error == silly::RouteError.None);
    capture(plan, "/a/b", "id", "a");
    capture(plan, "/a/b", "rest", "b");
    capture(plan, "/a", "rest", "");
    assert(silly::match_route(plan, "GET", "/a/b/c").result == silly::RouteMatchResult.SegmentLimit);
    assert(silly::match_route(plan, "GET", "/a//").result == silly::RouteMatchResult.SegmentLimit);
    assert(!silly::route_capture(plan, 0, "/a/b/c", "rest").present);
    var tightened = plan;
    tightened.limits.captures_max = 1;
    assert(silly::match_route(tightened, "GET", "/a/b").result == silly::RouteMatchResult.CaptureLimit);
    assert(!silly::route_capture(tightened, 0, "/a/b", "id").present);
    tightened.limits.captures_max = 0;
    assert(silly::match_route(tightened, "GET", "/a").result == silly::RouteMatchResult.CaptureLimit);
}

fn capture_rejected(plan: silly::RoutePlan<route_test::Action>) {
    assert(plan.issue.error == silly::RouteError.CaptureLimit);
    assert(plan.issue.route_id == 0);
}

fn zero_capture(router: silly::Router<route_test::Action>&) {
    router.get("/literal", route_test::Action.Static);
}

fn zero_values(plan: silly::RoutePlan<route_test::Action>) {
    assert(plan.issue.error == silly::RouteError.None);
    route_test::selected(plan, "GET", "/literal", route_test::Action.Static);
}

fn::main() {
    route_test::with_plan(silly::RouteLimits {
        }, router_test::define, router_test::raw);
    route_test::with_plan(silly::RouteLimits {
            segments_max: 2,
            captures_max: 2,
            ..
        }, router_test::limited, router_test::limit_values);
    route_test::with_plan(silly::RouteLimits {
            captures_max: 1,
            ..
        }, router_test::limited, router_test::capture_rejected);
    route_test::with_plan(silly::RouteLimits {
            captures_max: 0,
            ..
        }, router_test::zero_capture, router_test::zero_values);
    print("exact raw routing and nested mounts passed");
}
