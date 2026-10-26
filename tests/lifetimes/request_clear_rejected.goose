// Expected rejection: request metadata still borrows the request byte owner.
namespace request_clear_rejected;

import silly from "../..";

import std;

fn::main() {
    var bytes: u8[>..] = [];
    bytes.append("GET / HTTP/1.1");
    const headers: silly::HeaderView[0] = [];
    let request = silly::Request {
        method: bytes[0..3],
        target: bytes[4..5],
        headers: headers,
        body_state: silly::RequestBody.Buffered {
            bytes: "",
        },
    };
    bytes.clear();
    assert(request.method == "GET");
}
