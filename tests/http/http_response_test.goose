// Exact framing for method/version/status/body-mode combinations; body bytes stay separate.
namespace http_response_test;

import silly from "../../";

import std;

import.response_fixture;

fn buffered_versions() {
    response_test::verify(response_test::Case {
            payload: "a\x00b",
            expected: "HTTP/1.1 200 OK\r\nContent-Length: 3\r\nConnection: close\r\n\r\n",
            content_length: 3,
            body_bytes: 3,
            ..
        });
    response_test::verify(response_test::Case {
            payload: "a\x00b",
            options: silly::ResponseWireOptions {
                http_minor: 0,
                ..
            },
            expected: "HTTP/1.0 200 OK\r\nContent-Length: 3\r\nConnection: close\r\n\r\n",
            content_length: 3,
            body_bytes: 3,
            ..
        });
    response_test::verify(response_test::Case {
            options: silly::ResponseWireOptions {
                close: false,
                ..
            },
            expected: "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n",
            close: false,
            ..
        });
    response_test::verify(response_test::Case {
            options: silly::ResponseWireOptions {
                http_minor: 0,
                close: false,
                ..
            },
            expected: "HTTP/1.0 200 OK\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n",
            close: false,
            ..
        });
}

fn stream_versions() {
    response_test::verify(response_test::Case {
            mode: silly::ResponseBodyMode.Stream,
            expected: "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n",
            framing: silly::ResponseFraming.Chunked,
            content_length: -1,
            body_bytes: -1,
            ..
        });
    response_test::verify(response_test::Case {
            mode: silly::ResponseBodyMode.Stream,
            options: silly::ResponseWireOptions {
                close: false,
                ..
            },
            expected: "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n",
            framing: silly::ResponseFraming.Chunked,
            content_length: -1,
            body_bytes: -1,
            close: false,
            ..
        });
    response_test::verify(response_test::Case {
            mode: silly::ResponseBodyMode.Stream,
            options: silly::ResponseWireOptions {
                http_minor: 0,
                close: false,
                ..
            },
            expected: "HTTP/1.0 200 OK\r\nConnection: close\r\n\r\n",
            framing: silly::ResponseFraming.Close,
            content_length: -1,
            body_bytes: -1,
            ..
        });
}

fn head_responses() {
    response_test::verify(response_test::Case {
            payload: "representation",
            options: silly::ResponseWireOptions {
                request_method: "HEAD",
                ..
            },
            expected: "HTTP/1.1 200 OK\r\nContent-Length: 14\r\nConnection: close\r\n\r\n",
            framing: silly::ResponseFraming.None,
            content_length: 14,
            ..
        });
    response_test::verify(response_test::Case {
            options: silly::ResponseWireOptions {
                http_minor: 0,
                request_method: "HEAD",
                representation_length: 42,
                ..
            },
            expected: "HTTP/1.0 200 OK\r\nContent-Length: 42\r\nConnection: close\r\n\r\n",
            framing: silly::ResponseFraming.None,
            content_length: 42,
            ..
        });
    response_test::verify(response_test::Case {
            mode: silly::ResponseBodyMode.Stream,
            options: silly::ResponseWireOptions {
                request_method: "HEAD",
                ..
            },
            expected: "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n",
            framing: silly::ResponseFraming.None,
            content_length: -1,
            ..
        });
    response_test::verify(response_test::Case {
            mode: silly::ResponseBodyMode.Stream,
            options: silly::ResponseWireOptions {
                request_method: "HEAD",
                representation_length: 9,
                ..
            },
            expected: "HTTP/1.1 200 OK\r\nContent-Length: 9\r\nConnection: close\r\n\r\n",
            framing: silly::ResponseFraming.None,
            content_length: 9,
            ..
        });
}

fn no_body(status: i32, minor: i32, expected: u8[:], framing: silly::ResponseFraming, length: i64) {
    for mode in[silly::ResponseBodyMode.Buffered, silly::ResponseBodyMode.Stream] {
        for method in["GET", "HEAD"] {
            response_test::verify(response_test::Case {
                    status: status,
                    mode: mode,
                    options: silly::ResponseWireOptions {
                        http_minor: minor,
                        request_method: method,
                        ..
                    },
                    expected: expected,
                    framing: framing,
                    content_length: length,
                    ..
                });
        }
    }
}

fn bodyless_statuses() {
    no_body(204, 1, "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n", silly::ResponseFraming.None, -1);
    no_body(204, 0, "HTTP/1.0 204 No Content\r\nConnection: close\r\n\r\n", silly::ResponseFraming.None, -1);
    no_body(205, 1, "HTTP/1.1 205 Reset Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        silly::ResponseFraming.Fixed, 0);
    no_body(205, 0, "HTTP/1.0 205 Reset Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        silly::ResponseFraming.Fixed, 0);
    no_body(304, 1, "HTTP/1.1 304 Not Modified\r\nConnection: close\r\n\r\n", silly::ResponseFraming.None, -1);
    no_body(304, 0, "HTTP/1.0 304 Not Modified\r\nConnection: close\r\n\r\n", silly::ResponseFraming.None, -1);
    response_test::verify(response_test::Case {
            status: 304,
            options: silly::ResponseWireOptions {
                http_minor: 0,
                representation_length: 123,
                ..
            },
            expected: "HTTP/1.0 304 Not Modified\r\nContent-Length: 123\r\nConnection: close\r\n\r\n",
            framing: silly::ResponseFraming.None,
            content_length: 123,
            ..
        });
}

fn redirect(response: silly::Response&) {
    assert(silly::begin_response(response, 301) == silly::ResponseError.None);
    assert(silly::add_header(response, "Location", "/destination?x=1") == silly::ResponseError.None);
    assert(silly::prepare_response(response) == silly::ResponseError.None);
    var head: u8[>..] = [];
    assert(silly::prepare_response_head(head, response, silly::ResponseWireOptions {
        }, 1024).error
        == silly::ResponseError.None);
    assert(head == str("HTTP/1.1 301 Moved Permanently\r\nContent-Length: 0\r\nConnection: close\r\n",
        "Location: /destination?x=1\r\n\r\n"));
}

fn metadata(response: silly::Response&) {
    assert(silly::begin_response(response, 299) == silly::ResponseError.None);
    assert(silly::append_body(response, "\x00\xff") == silly::ResponseError.None);
    assert(silly::add_header(response, "Location", "/next?x=1") == silly::ResponseError.None);
    assert(silly::add_header(response, "Set-Cookie", "a=1") == silly::ResponseError.None);
    assert(silly::add_header(response, "set-cookie", "b=2") == silly::ResponseError.None);
    assert(silly::add_header(response, "X-Empty", "") == silly::ResponseError.None);
    assert(silly::prepare_response(response) == silly::ResponseError.None);
    var head: u8[>..] = [];
    let plan = silly::prepare_response_head(head, response, silly::ResponseWireOptions {
        }, 1024);
    assert(plan.error == silly::ResponseError.None);
    assert(head == str("HTTP/1.1 299 Response\r\nContent-Length: 2\r\nConnection: close\r\n",
        "Location: /next?x=1\r\nSet-Cookie: a=1\r\nset-cookie: b=2\r\nX-Empty: \r\n\r\n"));
    assert(find(head, "Content-Type") < 0);
    assert(response.output == "\x00\xff");
}

fn::main() {
    http_response_test::buffered_versions();
    http_response_test::stream_versions();
    http_response_test::head_responses();
    http_response_test::bodyless_statuses();
    response_test::with_response(http_response_test::metadata);
    response_test::with_response(http_response_test::redirect);
    print("response framing matrix passed");
}
