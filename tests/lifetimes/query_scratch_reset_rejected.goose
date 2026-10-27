// Expected rejection: decoded query values retain caller-owned scratch storage.
namespace query_scratch_reset_rejected;

import silly from "../..";

import std;

fn::main() {
    var scratch: u8[>..] = [];
    let pairs = silly::parse_query("token=a%2Bb", scratch);
    assert(pairs.error == silly::QueryError.None);
    let value = silly::get(pairs, "token");
    scratch.clear();
    print(value.value);
}
