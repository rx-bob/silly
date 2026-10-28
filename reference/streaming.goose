// Runnable finite SSE producer with owned state, heartbeat timers and cancellation cleanup.
// The shared example uses the production step and six-argument serve contracts.

import events_routes from "../examples";
import silly from "..";

import std;

fn::main() {
    let result = events_example::run(8083);
    if !result.ok {
        print(result.message);
        exit(1);
    }
}
