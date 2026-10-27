// Expected rejection: typed JSON strings retain their input and decode scratch owners.
namespace json_binding_input_reset_rejected;

import silly from "../..";

import std;

struct Input {
    name: const u8[:]
}
fn::main() {
    var input: u8[>..] = [];
    input.append("{\"name\":\"raw\"}");
    var scratch: u8[>..] = [];
    let document = silly::parse_json(input, scratch);
    let bound = silly::bind_json<json_binding_input_reset_rejected::Input>(document.value);
    input.clear();
    print(bound.value.name);
}
