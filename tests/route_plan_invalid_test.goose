// Route declarations fail with stable route identities before serving requests.
namespace route_plan_invalid_test;

import silly from "..";

import std;

fn rejected(method: u8[:], path: u8[:], expected: silly::RouteError, limits: silly::RouteLimits) {
    var entries: silly::RouteEntry<i64>[>..] = [];
    var segments: silly::RouteSegment[>..] = [];
    var bytes: u8[>..] = [];
    var router = silly::Router<i64> {
        entries: entries,
        segments: segments,
        bytes: bytes,
        limits: limits,
        ..
    };
    silly::add(router, method, path, 1);
    let first = router.issue;
    silly::get(router, "/ignored", 2);
    let plan = silly::prepare(router);
    assert(plan.issue.error == expected);
    assert(plan.issue.route_id == 0);
    assert(plan.issue.error == first.error);
    assert(plan.issue.route_id == first.route_id);
    assert(silly::match_route(plan, "GET", "/ignored").result == silly::RouteMatchResult.InvalidPlan);
}

fn conflict(first: u8[:], second: u8[:], expected: silly::RouteError) {
    var entries: silly::RouteEntry<i64>[>..] = [];
    var segments: silly::RouteSegment[>..] = [];
    var bytes: u8[>..] = [];
    var router = silly::Router<i64> {
        entries: entries,
        segments: segments,
        bytes: bytes,
        ..
    };
    silly::get(router, first, 1);
    silly::get(router, second, 2);
    let plan = silly::prepare(router);
    assert(plan.issue.error == expected);
    assert(plan.issue.route_id == 1);
    assert(plan.issue.conflicting_route_id == 0);
}

fn syntax() {
    let limits = silly::RouteLimits {
    };
    rejected("BAD METHOD", "/", silly::RouteError.InvalidMethod, limits);
    rejected("GET\r", "/", silly::RouteError.InvalidMethod, limits);
    rejected("GET", "relative", silly::RouteError.InvalidPath, limits);
    rejected("GET", "/bad?query", silly::RouteError.InvalidPath, limits);
    rejected("GET", "/bad#fragment", silly::RouteError.InvalidPath, limits);
    rejected("GET", "/bad\nline", silly::RouteError.InvalidPath, limits);
    rejected("GET", "/:", silly::RouteError.InvalidCapture, limits);
    rejected("GET", "/:bad-name", silly::RouteError.InvalidCapture, limits);
    rejected("GET", "/:id/:id", silly::RouteError.DuplicateCapture, limits);
    rejected("GET", "/:id/*id", silly::RouteError.DuplicateCapture, limits);
    rejected("GET", "/files/*path/more", silly::RouteError.WildcardPlacement, limits);
    conflict("/same", "/same", silly::RouteError.DuplicateRoute);
    conflict("/:id/edit", "/:name/edit", silly::RouteError.AmbiguousCapture);
    conflict("/files/*path", "/files/*rest", silly::RouteError.AmbiguousCapture);
}

fn capacities() {
    rejected("GET", "/", silly::RouteError.InvalidLimits, silly::RouteLimits {
            path_bytes_max: 0,
            ..
        });
    rejected("GET", "/", silly::RouteError.RouteLimit, silly::RouteLimits {
            routes_max: 0,
            ..
        });
    rejected("GET", "/long", silly::RouteError.PathLimit, silly::RouteLimits {
            path_bytes_max: 4,
            ..
        });
    rejected("GET", "/a/b", silly::RouteError.SegmentLimit, silly::RouteLimits {
            segments_max: 1,
            ..
        });
    rejected("GET", "/:a/:b", silly::RouteError.CaptureLimit, silly::RouteLimits {
            captures_max: 1,
            ..
        });
    rejected("GET", "/a/b", silly::RouteError.SegmentLimit, silly::RouteLimits {
            compiled_segments_max: 1,
            ..
        });
    rejected("GET", "/", silly::RouteError.StorageLimit, silly::RouteLimits {
            storage_bytes_max: 3,
            ..
        });
    rejected("LONG", "/", silly::RouteError.InvalidMethod, silly::RouteLimits {
            method_bytes_max: 3,
            ..
        });
}

fn options_and_freeze(options: silly::RouteOptions) {
    var entries: silly::RouteEntry<i64>[>..] = [];
    var segments: silly::RouteSegment[>..] = [];
    var bytes: u8[>..] = [];
    var router = silly::Router<i64> {
        entries: entries,
        segments: segments,
        bytes: bytes,
        ..
    };
    silly::post(router, "/stream", 1, options);
    assert(silly::prepare(router).issue.error == silly::RouteError.UnsupportedOptions);
}

fn prepared_registration() {
    var entries: silly::RouteEntry<i64>[>..] = [];
    var segments: silly::RouteSegment[>..] = [];
    var bytes: u8[>..] = [];
    var router = silly::Router<i64> {
        entries: entries,
        segments: segments,
        bytes: bytes,
        ..
    };
    silly::get(router, "/ready", 1);
    assert(silly::prepare(router).issue.error == silly::RouteError.None);
    silly::get(router, "/late", 2);
    assert(router.issue.error == silly::RouteError.AlreadyPrepared);
    assert(router.entries.len == 1);
}

fn::main() {
    route_plan_invalid_test::syntax();
    route_plan_invalid_test::capacities();
    route_plan_invalid_test::options_and_freeze(silly::RouteOptions {
            body: silly::BodyMode.Streamed,
            ..
        });
    route_plan_invalid_test::options_and_freeze(silly::RouteOptions {
            body_bytes_max: -2,
            ..
        });
    route_plan_invalid_test::prepared_registration();
    print("route declaration failures passed");
}
