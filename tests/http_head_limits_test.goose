// Exact line, header section, field and aggregate bounds use classified operating errors.
namespace http_head_limits_test;

import silly from "..";

import std;

fn result(input: u8[:], limits: silly::Limits) -> silly::HeadResult {
    var fields: silly::HeaderView[>..] = [];
    return silly::parse_head(input, fields, limits).result;
}

fn exact_limits() {
    let input = "GET / HTTP/1.0\r\nX: a\r\n\r\n";
    let exact = silly::Limits {
        head_bytes_max: input.len,
        header_count_max: 1,
        header_bytes_max: 3,
        request_line_bytes_max: 16,
        header_line_bytes_max: 6,
        header_section_bytes_max: 8,
        ..
    };
    assert(result(input, exact) == silly::HeadResult.Complete);
    var limits = exact;
    limits.request_line_bytes_max = 15;
    assert(result(input, limits) == silly::HeadResult.RequestLineLimit);
    limits = exact;
    limits.header_line_bytes_max = 5;
    assert(result(input, limits) == silly::HeadResult.HeaderLimit);
    limits = exact;
    limits.header_section_bytes_max = 7;
    assert(result(input, limits) == silly::HeadResult.HeaderLimit);
    limits = exact;
    limits.head_bytes_max = input.len - 1;
    assert(result(input, limits) == silly::HeadResult.HeadLimit);
    limits = exact;
    limits.header_count_max = 0;
    assert(result(input, limits) == silly::HeadResult.HeaderLimit);
    limits = exact;
    limits.header_bytes_max = 2;
    assert(result(input, limits) == silly::HeadResult.HeaderLimit);
}

fn defaults_and_trailing_bytes() {
    let defaults = silly::Limits {
    };
    assert(defaults.request_line_bytes_max == 8192);
    assert(defaults.header_line_bytes_max == 16384);
    assert(defaults.header_section_bytes_max == 16384);
    let head = "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 100000\r\n\r\n";
    var input: u8[>..] = [];
    input.append(head);
    let chunk: u8[1000] = ['b'; 1000];
    for count in 100 {
        input.append(chunk);
    }
    let limits = silly::Limits {
        head_bytes_max: head.len,
        ..
    };
    var scan = silly::HeadScan {
    };
    assert(silly::scan_head(scan, input, limits) == silly::HeadResult.Complete);
    assert(scan.head_bytes == head.len);
    var fields: silly::HeaderView[>..] = [];
    let parsed = silly::parse_head(input, fields, limits);
    assert(parsed.result == silly::HeadResult.Complete);
    assert(parsed.content_length == 100000);
    assert(input[parsed.head_bytes..].len == 100000);
}

fn classified_failures() {
    assert(silly::head_status(silly::HeadResult.BadRequest) == 400);
    assert(silly::head_status(silly::HeadResult.Truncated) == 400);
    assert(silly::head_status(silly::HeadResult.RequestLineLimit) == 414);
    assert(silly::head_status(silly::HeadResult.HeaderLimit) == 431);
    assert(silly::head_status(silly::HeadResult.HeadLimit) == 431);
    assert(silly::head_status(silly::HeadResult.UnsupportedVersion) == 505);
    assert(silly::head_status(silly::HeadResult.UnsupportedTransferCoding) == 501);
    assert(silly::head_status(silly::HeadResult.Complete) == 0);
    assert(silly::head_status(silly::HeadResult.NeedMore) == 0);
    let input = "GET / HTTP/1.0\r\n\r\n";
    var scan = silly::HeadScan {
    };
    let limits = silly::Limits {
        request_line_bytes_max: 5,
        ..
    };
    assert(silly::scan_head(scan, input, limits) == silly::HeadResult.RequestLineLimit);
    assert(silly::scan_head(scan, "GET /ok HTTP/1.0\r\n\r\n", silly::Limits {
        })
        == silly::HeadResult.RequestLineLimit);
}

fn default_envelope() {
    var input: u8[>..] = [];
    input.append("GET /");
    for index in 8192 - 16 {
        input.push('a');
    }
    input.append(" HTTP/1.0\r\n\r\n");
    assert(input.len == 8194);
    assert(result(input, silly::Limits {
        }) == silly::HeadResult.Complete);
    assert(result(input, silly::Limits {
            request_line_bytes_max: 8191,
            ..
        })
        == silly::HeadResult.RequestLineLimit);
    input.clear();
    input.append("GET / HTTP/1.0\r\nX: ");
    for index in 16384 - 7 {
        input.push('a');
    }
    input.append("\r\n\r\n");
    assert(input.len == 16 + 16384);
    assert(result(input, silly::Limits {
        }) == silly::HeadResult.Complete);
    assert(result(input, silly::Limits {
            header_section_bytes_max: 16383,
            ..
        })
        == silly::HeadResult.HeaderLimit);
    input.clear();
    input.append("GET / HTTP/1.0\r\nX: ");
    for index in 16384 - 5 {
        input.push('a');
    }
    input.append("\r\n\r\n");
    assert(result(input, silly::Limits {
            header_section_bytes_max: 16386,
            ..
        })
        == silly::HeadResult.Complete);
    assert(result(input, silly::Limits {
            header_line_bytes_max: 16383,
            header_section_bytes_max: 16386,
            ..
        })
        == silly::HeadResult.HeaderLimit);
}

fn::main() {
    http_head_limits_test::exact_limits();
    http_head_limits_test::defaults_and_trailing_bytes();
    http_head_limits_test::classified_failures();
    http_head_limits_test::default_envelope();
    print("http head limit contracts passed");
}
