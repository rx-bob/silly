// Unsupported enum output must be selected explicitly by a custom writer.

import silly from "../..";

enum Unsupported {
    A,
    B
}
fn::main() {
    var output: u8[>..] = [];
    var writer = silly::JsonWriter {
        output: output,
        cap: 64,
        ..
    };
    let value = Unsupported.A;
    silly::write_json(writer, value);
}
