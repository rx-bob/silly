// Expected rejection: a handler's request facade is read-only.
namespace immutable_request_rejected;

import silly from "../..";

fn mutate(request: const silly::Request&) {
    request.method = "POST";
}

fn::main() {
    const headers: silly::HeaderView[0] = [];
    let request = silly::Request {
        method: "GET",
        target: "/",
        headers: headers,
        body_state: silly::RequestBody.Buffered {
            bytes: "",
        },
    };
    immutable_request_rejected::mutate(request);
}
