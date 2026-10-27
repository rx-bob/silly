// Expected rejection: typed binding outputs must be fixed size.
namespace json_owned_binding_rejected;

import silly from "../..";

struct Owned {
    name: u8[>..]
}
fn::main() {
    var scratch: u8[>..] = [];
    let document = silly::parse_json("{}", scratch);
    let bound = silly::bind_json<json_owned_binding_rejected::Owned>(document.value);
}
