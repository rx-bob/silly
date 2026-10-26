// Shared driver-owned route storage for pure preparation and dispatch fixtures.
namespace route_test;

import silly from "..";

import std;

enum Action {
    Root,
    Static,
    Captured,
    CatchAll,
    Update,
    Fallback,
}

fn with_plan<D, V>(limits: silly::RouteLimits) {
    var entries: silly::RouteEntry<Action>[>..] = [];
    var segments: silly::RouteSegment[>..] = [];
    var bytes: u8[>..] = [];
    var router = silly::Router<Action> {
        entries: entries,
        segments: segments,
        bytes: bytes,
        limits: limits,
        ..
    };
    D(router);
    let plan = silly::prepare(router);
    V(plan);
}

fn selected(plan: silly::RoutePlan<Action>, method: u8[:], path: u8[:], action: Action) {
    let found = silly::match_route(plan, method, path);
    assert(found.result == silly::RouteMatchResult.Matched);
    assert(found.route_id >= 0);
    assert(plan.entries[found.route_id].action == action);
}

fn missing(plan: silly::RoutePlan<Action>, method: u8[:], path: u8[:]) {
    let found = silly::match_route(plan, method, path);
    assert(found.result == silly::RouteMatchResult.NotFound);
    assert(found.route_id == -1);
}
