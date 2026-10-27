// Expected rejection: fixed-size query views retain decoded scratch through lookup.
namespace query_view_reset_rejected;

import silly from "../..";

import std;

fn::main() {
    var scratch: u8[>..] = [];
    let view = silly::parse_query_view("token=a%2Bb", scratch);
    assert(view.error == silly::QueryError.None);
    let value = silly::get(view, "token");
    scratch.clear();
    print(value.value);
}
