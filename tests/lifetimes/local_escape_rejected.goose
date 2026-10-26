// Expected rejection: returned request metadata cannot borrow function-local storage.
namespace local_escape_rejected;

import silly from "../..";

import std;

const EMPTY_HEADERS: silly::HeaderView[0] = [];

fn escaped_request() -> silly::Request {
    var bytes: u8[>..] = [];
    bytes.append("GET /");
    return silly::Request {
        method: bytes[0..3],
        target: bytes[4..5],
        headers: EMPTY_HEADERS,
        body_state: silly::RequestBody.Buffered {
            bytes: "",
        },
    };
}

fn::main() {
    let request = local_escape_rejected::escaped_request();
    assert(request.method == "GET");
}
