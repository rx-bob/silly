// Every audited declaration reaches a real statically dispatched deterministic handler.
namespace promptnook_routes_test;

import routes from "../examples/promptnook_contract";
import silly from "..";

import std;

import.promptnook_route_fixture;
import.promptnook_route_manifest;
import.promptnook_route_negative;

fn run_listener(cases: promptnook_contract::RouteCase[:], listener: u8[:]) {
    var entries: silly::RouteEntry<promptnook_contract::Route>[>..] = [];
    var segments: silly::RouteSegment[>..] = [];
    var bytes: u8[>..] = [];
    var router = silly::Router<promptnook_contract::Route> {
        entries: entries,
        segments: segments,
        bytes: bytes,
        ..
    };
    var app = promptnook_contract::App {
    };
    if listener == "api" {
        promptnook_contract::routes(router, app);
    } else {
        promptnook_contract::portal_routes(router, app);
    }
    var plan = silly::prepare(router);
    assert(plan.issue.error == silly::RouteError.None);
    var count: i64 = 0;
    for item in cases {
        if item.listener != listener {
            continue;
        }
        let method = if item.method.len == 0 {
            "TRACE"
        } else {
            item.method
        };
        let selected = silly::match_route(plan, method, item.target);
        assert(selected.result == silly::RouteMatchResult.Matched);
        assert(silly::route_path(plan, selected.route_id) == item.path);
        assert(silly::route_method(plan, selected.route_id) == item.method);
        promptnook_route_test::exercise(plan, method, item.target, item.route,
            promptnook_route_test::expected_status(item), app);
        promptnook_route_test::verify_captures(plan, selected.route_id, item.target);
        count += 1;
    }
    assert(count == plan.entries.len);
    assert(app.handled == count);
    if listener == "api" {
        promptnook_route_test::api_negatives(plan);
    } else {
        promptnook_route_test::portal_negatives(plan);
    }
}

fn::main() {
    var cases: promptnook_contract::RouteCase[>..] = [];
    promptnook_contract::inventory(cases);
    assert(cases.len == 181);
    promptnook_route_test::verify_manifest(cases);
    promptnook_routes_test::run_listener(cases, "api");
    promptnook_routes_test::run_listener(cases, "portal");
    print("181 audited consumer route declarations and adapter dispatch contracts passed");
}
