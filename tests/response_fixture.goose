// Independent expected wire bytes and separately owned response payloads.
namespace response_test;

import silly from "..";

import std;

struct Case {
    status: i32 = 200,
    mode: silly::ResponseBodyMode = silly::ResponseBodyMode.Buffered,
    payload: const u8[:] = "",
    options: silly::ResponseWireOptions = silly::ResponseWireOptions {
    },
    expected: const u8[:],
    framing: silly::ResponseFraming = silly::ResponseFraming.Fixed,
    content_length: i64 = 0,
    body_bytes: i64 = 0,
    close: bool = true,
}

fn verify(test: Case) {
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
    assert(silly::begin_response(response, test.status) == silly::ResponseError.None);
    assert(silly::append_body(response, test.payload) == silly::ResponseError.None);
    response.mode = test.mode;
    assert(silly::prepare_response(response) == silly::ResponseError.None);
    var head: u8[>..] = [];
    let short = silly::prepare_response_head(head, response, test.options, test.expected.len - 1);
    assert(short.error == silly::ResponseError.HeaderBytesLimit);
    assert(head.len == 0);
    assert(response.phase == silly::ResponsePhase.Prepared);
    let plan = silly::prepare_response_head(head, response, test.options, test.expected.len);
    assert(plan.error == silly::ResponseError.None);
    assert(head == test.expected);
    assert(plan.framing == test.framing);
    assert(plan.content_length == test.content_length);
    assert(plan.body_bytes == test.body_bytes);
    assert(plan.close == test.close);
    assert(!plan.informational);
    assert(output == test.payload);
    assert(response.phase == silly::ResponsePhase.Prepared);
    let again = silly::prepare_response_head(head, response, test.options, 4096);
    assert(again.error == silly::ResponseError.InvalidState);
    assert(head == test.expected);
}

fn with_response<F>() {
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
    F(response);
}
