// Expected rejection: prepared route inventory still borrows the declaration byte owner.
namespace route_plan_clear_rejected;

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
    bytes.clear();
    print(silly::route_path(plan, 0));
}
