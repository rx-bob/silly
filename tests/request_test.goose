// Exact request caps and invalid metadata are operating errors, never parser assertions.
namespace request_test;

import silly from "..";

import std;

fn request_bounds() {
    const headers = [silly::HeaderView {
            name: "X",
            value: "ab"
        }];
    let request = silly::Request {
        method: "POST",
        target: "/",
        headers: headers,
        body_state: silly::RequestBody.Buffered {
            bytes: "body"
        },
    };
    let exact = silly::Limits {
        head_bytes_max: 10,
        header_count_max: 1,
        header_bytes_max: 3,
        body_bytes_max: 4,
        ..
    };
    assert(silly::validate_request(request, 10, exact) == silly::RequestError.None);
    assert(silly::validate_request(request, 11, exact) == silly::RequestError.HeadLimit);
    assert(silly::validate_request(request, -1, exact) == silly::RequestError.HeadLimit);
    var limits = exact;
    limits.header_count_max = 0;
    assert(silly::validate_request(request, 10, limits) == silly::RequestError.HeaderCountLimit);
    limits = exact;
    limits.header_bytes_max = 2;
    assert(silly::validate_request(request, 10, limits) == silly::RequestError.HeaderBytesLimit);
    limits = exact;
    limits.body_bytes_max = 3;
    assert(silly::validate_request(request, 10, limits) == silly::RequestError.BodyLimit);
    limits = exact;
    limits.head_bytes_max = 0;
    assert(silly::validate_request(request, 10, limits) == silly::RequestError.InvalidLimits);
}

fn request_failures() {
    const headers = [silly::HeaderView {
            name: "Bad Name",
            value: ""
        }];
    let bad_name = silly::Request {
        method: "GET",
        target: "/",
        headers: headers,
        ..
    };
    let limits = silly::Limits {
    };
    assert(silly::validate_request(bad_name, 30, limits) == silly::RequestError.InvalidHeader);
    const invalid_values = [silly::HeaderView {
            name: "X",
            value: "injected\nvalue"
        }];
    let bad_value = silly::Request {
        method: "GET",
        target: "/",
        headers: invalid_values,
        ..
    };
    assert(silly::validate_request(bad_value, 30, limits) == silly::RequestError.InvalidHeader);
    let failed = silly::Request {
        method: "GET",
        target: "/",
        body_state: silly::RequestBody.Failed {
            error: silly::BodyError.Disconnected
        },
        ..
    };
    assert(silly::validate_request(failed, 30, limits) == silly::RequestError.BodyFailed);
    let streamed = silly::Request {
        method: "POST",
        target: "/",
        body_state: silly::RequestBody.Streamed,
        ..
    };
    assert(silly::validate_request(streamed, 30, limits) == silly::RequestError.None);
}

fn::main() {
    request_test::request_bounds();
    request_test::request_failures();
    print("request contracts passed");
}
