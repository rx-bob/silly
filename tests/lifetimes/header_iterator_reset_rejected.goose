// Expected rejection: request-local header access retains its backing owner.
namespace header_iterator_reset_rejected;

import silly from "../..";

import std;

fn::main() {
    var bytes: u8[>..] = [];
    bytes.append("GET / HTTP/1.1\r\nHost: x\r\nX: retained\r\n\r\n");
    var fields: silly::HeaderView[>..] = [];
    var index: silly::HeaderIndexEntry[>..] = [];
    let parsed = silly::parse_head(bytes, fields, index, silly::Limits {
        });
    assert(parsed.result == silly::HeadResult.Complete);
    let request = silly::Request {
        method: parsed.method,
        target: parsed.target,
        headers: fields,
        header_index: index,
        ..
    };
    var values = silly::header_values(request, "x");
    bytes.clear();
    print(silly::next_header(values).value);
}
