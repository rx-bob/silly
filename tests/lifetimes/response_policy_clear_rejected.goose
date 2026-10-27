// A prepared plan pins the router-owned immutable policy snapshot array.

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
    silly::error_policy(router, 1);
    let plan = silly::prepare(router);
    router.response_policies.clear();
    assert(plan.response_policies[0].error_policy == 1);
}
