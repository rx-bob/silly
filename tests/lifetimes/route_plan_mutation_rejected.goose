// Expected rejection: prepared route entries expose immutable typed action data.
namespace route_plan_mutation_rejected;

import silly from "../..";

import std;

fn::main() {
    var entries: silly::RouteEntry<i64>[>..] = [];
    var segments: silly::RouteSegment[>..] = [];
    var bytes: u8[>..] = [];
    var router = silly::Router<i64> {
        entries: entries,
        segments: segments,
        bytes: bytes,
        ..
    };
    silly::get(router, "/retained", 1);
    let plan = silly::prepare(router);
    plan.entries[0].action = 2;
    print(plan.entries[0].action);
}
