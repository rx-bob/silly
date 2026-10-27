// E10.S1 replaces the earlier illustrative inventory with all source-audited declarations.
namespace route_inventory_test;

import routes from "../examples/promptnook_contract";
import silly from "..";

import std;

fn verify(cases: promptnook_contract::RouteCase[:], listener: u8[:]) {
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
    let plan = silly::prepare(router);
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
        let found = silly::match_route(plan, method, item.target);
        assert(found.result == silly::RouteMatchResult.Matched);
        assert(plan.entries[found.route_id].action == item.route);
        assert(silly::route_path(plan, found.route_id) == item.path);
        assert(silly::route_method(plan, found.route_id) == item.method);
        count += 1;
    }
    assert(count == plan.entries.len);
}

fn::main() {
    var cases: promptnook_contract::RouteCase[>..] = [];
    promptnook_contract::inventory(cases);
    assert(cases.len == 181);
    route_inventory_test::verify(cases, "api");
    route_inventory_test::verify(cases, "portal");
    print("complete audited consumer route inventory passed");
}
