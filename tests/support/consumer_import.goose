// Standalone consumer: import the package, instantiate its public marker types, and own main.
namespace consumer_import;

import silly from "../../";

import std;

struct Application {
    state: silly::NoState,
    stream: silly::NoStream,
    value: i64,
}

fn::main() {
    let app = consumer_import::Application {
        state: silly::NoState {
        },
        stream: silly::NoStream {
        },
        value: 42,
    };
    assert(app.value == 42);
    print("silly package import passed");
}
