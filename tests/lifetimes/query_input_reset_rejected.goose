// Expected rejection: unchanged query values borrow the original input owner.
namespace query_input_reset_rejected;

import silly from "../..";

import std;

fn::main() {
    var input: u8[>..] = [];
    input.append("email=a@example.test");
    var scratch: u8[>..] = [];
    let pairs = silly::parse_query(input, scratch);
    assert(pairs.error == silly::QueryError.None);
    let value = silly::get(pairs, "email");
    input.clear();
    print(value.value);
}
