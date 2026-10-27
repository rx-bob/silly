// Invalid response metadata fails atomically before any header bytes are committed.
namespace http_response_invalid_test;

import silly from "..";

import std;

import.response_fixture;

fn reject(status: i32, payload: u8[:], options: silly::ResponseWireOptions, error: silly::ResponseError) {
    var fields: silly::HeaderField[>..] = [];
    var headers: u8[>..] = [];
    var output: u8[>..] = [];
    var response = silly::Response {
        limits: silly::Limits {
        },
        header_fields: fields,
        header_bytes: headers,
        output: output,
        ..
    };
    assert(silly::begin_response(response, status) == silly::ResponseError.None);
    assert(silly::append_body(response, payload) == silly::ResponseError.None);
    assert(silly::prepare_response(response) == silly::ResponseError.None);
    var head: u8[>..] = [];
    assert(silly::prepare_response_head(head, response, options, 1024).error == error);
    assert(head.len == 0);
    assert(response.phase == silly::ResponsePhase.Prepared);
    assert(output == payload);
}

fn states() {
    for status in[204, 205, 304] {
        reject(status as i32, "forbidden", silly::ResponseWireOptions {
            }, silly::ResponseError.InvalidState);
    }
    reject(200, "body", silly::ResponseWireOptions {
            http_minor: 2,
            ..
        }, silly::ResponseError.InvalidState);
    reject(200, "body", silly::ResponseWireOptions {
            request_method: "CONNECT",
            ..
        },
        silly::ResponseError.InvalidState);
    reject(200, "body", silly::ResponseWireOptions {
            representation_length: 4,
            ..
        },
        silly::ResponseError.InvalidState);
    reject(200, "body", silly::ResponseWireOptions {
            request_method: "HEAD",
            representation_length: 5,
            ..
        },
        silly::ResponseError.InvalidState);
    reject(304, "", silly::ResponseWireOptions {
            representation_length: -2,
            ..
        },
        silly::ResponseError.InvalidLimits);
}

fn reserved(name: u8[:]) {
    var fields: silly::HeaderField[>..] = [];
    var headers: u8[>..] = [];
    var output: u8[>..] = [];
    var response = silly::Response {
        limits: silly::Limits {
        },
        header_fields: fields,
        header_bytes: headers,
        output: output,
        ..
    };
    assert(silly::begin_response(response, 200) == silly::ResponseError.None);
    assert(silly::add_header(response, name, "0") == silly::ResponseError.None);
    assert(silly::prepare_response(response) == silly::ResponseError.None);
    var head: u8[>..] = [];
    let plan = silly::prepare_response_head(head, response, silly::ResponseWireOptions {
        }, 1024);
    assert(plan.error == silly::ResponseError.InvalidHeader);
    assert(head.len == 0);
}

fn injection(name: u8[:], value: u8[:]) {
    var fields: silly::HeaderField[>..] = [];
    var headers: u8[>..] = [];
    var output: u8[>..] = [];
    var response = silly::Response {
        limits: silly::Limits {
        },
        header_fields: fields,
        header_bytes: headers,
        output: output,
        ..
    };
    assert(silly::begin_response(response, 200) == silly::ResponseError.None);
    assert(silly::add_header(response, name, value) == silly::ResponseError.InvalidHeader);
    assert(response.phase == silly::ResponsePhase.Failed);
    assert(fields.len == 0);
    assert(headers.len == 0);
    var head: u8[>..] = [];
    assert(silly::prepare_response_head(head, response, silly::ResponseWireOptions {
        }, 1024).error
        == silly::ResponseError.InvalidState);
    assert(head.len == 0);
}

fn head_capacity(response: silly::Response&) {
    assert(silly::begin_response(response, 200) == silly::ResponseError.None);
    assert(silly::add_header(response, "X", "abc") == silly::ResponseError.None);
    assert(silly::prepare_response(response) == silly::ResponseError.None);
    let expected = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\nX: abc\r\n\r\n";
    var head: u8[>..] = [];
    assert(silly::prepare_response_head(head, response, silly::ResponseWireOptions {
        }, -1).error
        == silly::ResponseError.InvalidLimits);
    for cap in expected.len {
        assert(silly::prepare_response_head(head, response, silly::ResponseWireOptions {
            }, cap).error
            == silly::ResponseError.HeaderBytesLimit);
        assert(head.len == 0);
    }
    assert(silly::prepare_response_head(head, response, silly::ResponseWireOptions {
        }, expected.len).error
        == silly::ResponseError.None);
    assert(head == expected);
}

fn::main() {
    http_response_invalid_test::states();
    for name in["Content-Length", "transfer-encoding", "CONNECTION", "Trailer", "Upgrade"] {
        http_response_invalid_test::reserved(name);
    }
    http_response_invalid_test::injection("Bad Name", "value");
    http_response_invalid_test::injection("X", "a\r\nInjected: yes");
    http_response_invalid_test::injection("X", "a\x00b");
    response_test::with_response(http_response_invalid_test::head_capacity);
    print("response precommit rejection contracts passed");
}
