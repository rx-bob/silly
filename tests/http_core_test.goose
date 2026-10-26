// Bounded GET parsing and separate buffered response-head framing.
namespace http_core_test;

import silly from "..";

import std;

fn parse_result(input: u8[:], limits: silly::Limits = silly::Limits {
    }) -> silly::HeadResult {
    var fields: silly::HeaderView[>..] = [];
    return silly::parse_get_head(input, fields, limits).result;
}

fn fragmented_head() {
    let input = "GET /hello?name=goose HTTP/1.1\r\nHost: localhost\r\nX: a\r\nx: b\r\n\r\n";
    var scan = silly::HeadScan {
    };
    for length in input.len {
        assert(silly::scan_head(scan, input[..length], 1024) == silly::HeadResult.NeedMore);
    }
    assert(silly::scan_head(scan, input, input.len) == silly::HeadResult.Complete);
    assert(scan.head_bytes == input.len);
    var fields: silly::HeaderView[>..] = [];
    let parsed = silly::parse_get_head(input, fields, silly::Limits {
        });
    assert(parsed.result == silly::HeadResult.Complete);
    assert(parsed.target == "/hello?name=goose");
    assert(parsed.http_minor == 1);
    assert(fields.len == 3);
    assert(fields[1].value == " a");
    assert(fields[2].value == " b");
    let first = silly::find_header(fields, "X");
    assert(first == 1);
    assert(silly::find_header(fields, "x", first + 1) == 2);
    var full = silly::HeadScan {
    };
    assert(silly::scan_head(full, "1234", 4) == silly::HeadResult.HeadLimit);
    var overflow = silly::HeadScan {
    };
    assert(silly::scan_head(overflow, input, input.len - 1) == silly::HeadResult.HeadLimit);
}

fn malformed_and_unsupported() {
    assert(parse_result("GET / HTTP/1.0\r\n\r\n") == silly::HeadResult.Complete);
    assert(parse_result("GET / HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n") == silly::HeadResult.Complete);
    assert(parse_result("GET / HTTP/1.1\r\n\r\n") == silly::HeadResult.BadRequest);
    assert(parse_result("GET / HTTP/1.1\r\nHost: \t\r\n\r\n") == silly::HeadResult.BadRequest);
    assert(parse_result("GET / HTTP/1.1\r\nHost: x\r\nhost: y\r\n\r\n") == silly::HeadResult.BadRequest);
    assert(parse_result("GET / HTTP/1.0\n\n") == silly::HeadResult.BadRequest);
    assert(parse_result("GET / HTTP/1.0\r\nX: bad\n\r\n") == silly::HeadResult.BadRequest);
    assert(parse_result("GET / HTTP/1.0\r\nBad Name: x\r\n\r\n") == silly::HeadResult.BadRequest);
    assert(parse_result("GET / HTTP/1.0\r\n folded\r\n\r\n") == silly::HeadResult.BadRequest);
    assert(parse_result("GET / HTTP/1.0\r\n\r\nbody") == silly::HeadResult.BadRequest);
    assert(parse_result("GET / HTTP/1.0\r\nContent-Length: -0\r\n\r\n") == silly::HeadResult.BadRequest);
    assert(parse_result("GET / HTTP/1.0\r\nContent-Length: 1\r\n\r\n") == silly::HeadResult.UnsupportedBody);
    assert(parse_result("GET / HTTP/1.0\r\nTransfer-Encoding: chunked\r\n\r\n") == silly::HeadResult.BadRequest);
    assert(parse_result("GET / HTTP/1.0\r\nExpect: 100-continue\r\n\r\n") == silly::HeadResult.UnsupportedBody);
    assert(parse_result("POST / HTTP/1.0\r\n\r\n") == silly::HeadResult.UnsupportedMethod);
    assert(parse_result("GET / HTTP/2.0\r\n\r\n") == silly::HeadResult.UnsupportedVersion);
}

fn parser_limits() {
    let input = "GET / HTTP/1.0\r\nX: a\r\n\r\n";
    assert(parse_result(input, silly::Limits {
            head_bytes_max: input.len,
            ..
        }) == silly::HeadResult.Complete);
    assert(parse_result(input, silly::Limits {
            head_bytes_max: input.len - 1,
            ..
        }) == silly::HeadResult.HeadLimit);
    assert(parse_result(input, silly::Limits {
            header_count_max: 0,
            ..
        }) == silly::HeadResult.HeaderLimit);
    assert(parse_result(input, silly::Limits {
            header_bytes_max: 2,
            ..
        }) == silly::HeadResult.HeaderLimit);
    assert(parse_result(input, silly::Limits {
            header_bytes_max: 3,
            ..
        }) == silly::HeadResult.Complete);
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

fn normal_response(response: silly::Response&) {
    assert(silly::begin_response(response, 200) == silly::ResponseError.None);
    assert(silly::append_body(response, "hello\n") == silly::ResponseError.None);
    assert(silly::add_header(response, "Content-Type", "text/plain") == silly::ResponseError.None);
    assert(silly::prepare_response(response) == silly::ResponseError.None);
    var head: u8[>..] = [];
    let expected = "HTTP/1.1 200 OK\r\nContent-Length: 6\r\nConnection: close\r\nContent-Type: text/plain\r\n\r\n";
    assert(silly::write_response_head(head, response, 1, expected.len - 1) == silly::ResponseError.HeaderBytesLimit);
    assert(head.len == 0);
    assert(silly::write_response_head(head, response, 1, expected.len) == silly::ResponseError.None);
    assert(head == expected);
    assert(response.output == "hello\n");
    assert(response.phase == silly::ResponsePhase.Prepared);
    assert(silly::write_response_head(head, response, 1, 1024) == silly::ResponseError.InvalidState);
}

fn conflict_response(response: silly::Response&) {
    assert(silly::begin_response(response, 200) == silly::ResponseError.None);
    assert(silly::add_header(response, "content-length", "123") == silly::ResponseError.None);
    assert(silly::prepare_response(response) == silly::ResponseError.None);
    var head: u8[>..] = [];
    assert(silly::write_response_head(head, response, 1, 1024) == silly::ResponseError.InvalidHeader);
    assert(head.len == 0);
}

fn empty_response(response: silly::Response&) {
    assert(silly::begin_response(response, 204) == silly::ResponseError.None);
    assert(silly::prepare_response(response) == silly::ResponseError.None);
    var head: u8[>..] = [];
    assert(silly::write_response_head(head, response, 0, 1024) == silly::ResponseError.None);
    assert(head == "HTTP/1.0 204 No Content\r\nConnection: close\r\n\r\n");
}

fn invalid_no_body(response: silly::Response&) {
    assert(silly::begin_response(response, 304) == silly::ResponseError.None);
    assert(silly::append_body(response, "wrong") == silly::ResponseError.None);
    assert(silly::prepare_response(response) == silly::ResponseError.None);
    var head: u8[>..] = [];
    assert(silly::write_response_head(head, response, 1, 1024) == silly::ResponseError.InvalidState);
    assert(head.len == 0);
}

fn::main() {
    http_core_test::fragmented_head();
    http_core_test::malformed_and_unsupported();
    http_core_test::parser_limits();
    http_core_test::with_response(http_core_test::normal_response);
    http_core_test::with_response(http_core_test::conflict_response);
    http_core_test::with_response(http_core_test::empty_response);
    http_core_test::with_response(http_core_test::invalid_no_body);
    print("http core contracts passed");
}
