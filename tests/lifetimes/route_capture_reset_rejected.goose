// Expected rejection: a raw capture retains the request target's backing owner.
namespace route_capture_reset_rejected;

import silly from "../..";

import std;

fn::main() {
    var target: u8[>..] = [];
    target.append("/retained");
    const segments = [silly::RouteSegment {
            kind: silly::RouteSegmentKind.Capture,
            start: 0,
            bytes: 2,
        }];
    let captures = silly::RouteCaptures {
        segments: segments,
        bytes: "id",
        path: target,
    };
    let value = silly::param(captures, "id");
    target.clear();
    print(value.value);
}
