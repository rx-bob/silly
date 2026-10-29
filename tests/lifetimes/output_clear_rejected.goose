// Expected rejection: transport's live output view prevents clearing its owner.
namespace output_clear_rejected;

import silly from "../../";

import std;

fn::main() {
    var output: u8[>..] = [];
    output.append("response");
    let transport_view = output[0..];
    output.clear();
    assert(transport_view == "response");
}
