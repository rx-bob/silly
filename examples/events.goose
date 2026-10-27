// Run and use an SSE client against http://127.0.0.1:8085/events.

import silly from "..";

import std;

import.events_routes;

fn::main() {
    let result = events_example::run(8085);
    if !result.ok {
        print(result.message);
        exit(1);
    }
}
