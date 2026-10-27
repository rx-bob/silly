// Informational heads are separate bounded blocks, never final response payloads.
namespace http_informational_test;

import silly from "..";

import std;

fn exact(status: i32, expected: u8[:]) {
    const fields: silly::HeaderView[0] = [];
    var head: u8[>..] = [];
    assert(silly::write_informational_head(head, status, fields, 1, expected.len - 1)
        == silly::ResponseError.HeaderBytesLimit);
    assert(head.len == 0);
    assert(silly::write_informational_head(head, status, fields, 1, expected.len) == silly::ResponseError.None);
    assert(head == expected);
    assert(find(head, "Content-Length") < 0);
    assert(find(head, "Transfer-Encoding") < 0);
    assert(find(head, "Connection") < 0);
    assert(silly::write_informational_head(head, status, fields, 1, 1024) == silly::ResponseError.InvalidState);
    assert(head == expected);
}

fn metadata() {
    const fields = [
        silly::HeaderView {
            name: "Link",
            value: "</a.css>; rel=preload"
        },
        silly::HeaderView {
            name: "link",
            value: "</b.js>; rel=preload"
        },
    ];
    var head: u8[>..] = [];
    let expected = "HTTP/1.1 103 Early Hints\r\nLink: </a.css>; rel=preload\r\nlink: </b.js>; rel=preload\r\n\r\n";
    assert(silly::write_informational_head(head, 103, fields, 1, expected.len - 1)
        == silly::ResponseError.HeaderBytesLimit);
    assert(head.len == 0);
    assert(silly::write_informational_head(head, 103, fields, 1, expected.len) == silly::ResponseError.None);
    assert(head == expected);
}

fn invalid() {
    const fields: silly::HeaderView[0] = [];
    var head: u8[>..] = [];
    for status in[99, 101, 200, 599] {
        assert(silly::write_informational_head(head, status as i32, fields, 1, 1024) != silly::ResponseError.None);
        assert(head.len == 0);
    }
    assert(silly::write_informational_head(head, 100, fields, 0, 1024) != silly::ResponseError.None);
    assert(silly::write_informational_head(head, 100, fields, 2, 1024) != silly::ResponseError.None);
    assert(silly::write_informational_head(head, 100, fields, 1, -1) == silly::ResponseError.InvalidLimits);
    assert(head.len == 0);
    for field in[
        silly::HeaderView {
            name: "Content-Length", value: "0"
        },
        silly::HeaderView {
            name: "transfer-encoding",
            value: "chunked"
        },
        silly::HeaderView {
            name: "Connection",
            value: "close"
        },
        silly::HeaderView {
            name: "Bad Name",
            value: "x"
        },
        silly::HeaderView {
            name: "X",
            value: "a\r\nInjected: yes"
        },
    ] {
        assert(silly::write_informational_head(head, 103, [field], 1, 1024) == silly::ResponseError.InvalidHeader);
        assert(head.len == 0);
    }
}

fn::main() {
    http_informational_test::exact(100, "HTTP/1.1 100 Continue\r\n\r\n");
    http_informational_test::exact(102, "HTTP/1.1 102 Processing\r\n\r\n");
    http_informational_test::exact(199, "HTTP/1.1 199 Response\r\n\r\n");
    http_informational_test::metadata();
    http_informational_test::invalid();
    print("informational response contracts passed");
}
