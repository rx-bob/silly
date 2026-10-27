// Optional references require an explicit null/value policy in a custom writer.

import silly from "../..";

struct Unsupported {
    value: i64?
}
fn::main() {
    var output: u8[>..] = [];
    var writer = silly::JsonWriter {
        output: output,
        cap: 64,
        ..
    };
    let value = Unsupported {
        value: null
    };
    silly::write_json(writer, value);
}
