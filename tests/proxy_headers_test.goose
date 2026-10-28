// Proxy request and response policies filter hop-by-hop fields and preserve end-to-end data.
namespace proxy_headers_test;

import client from "../client";
import header_forwarding from "../client";
import proxy_target from "../client";
import silly from "..";

import std;

fn requests() {
    let fields = [silly::HeaderView {
            name: "Connection",
            value: "X-Hop, authorization"
        },
        silly::HeaderView {
            name: "X-Hop",
            value: "discard"
        },
        silly::HeaderView {
            name: "Authorization",
            value: "secret"
        },
        silly::HeaderView {
            name: "Host",
            value: "incoming"
        },
        silly::HeaderView {
            name: "X-Test",
            value: "old"
        },
        silly::HeaderView {
            name: "Content-Length",
            value: "4"
        }];
    let request = silly::Request {
        method: "POST",
        target: "/",
        headers: fields,
        ..
    };
    let overrides = [silly_client::RequestHeader {
            name: "X-Test",
            value: "first"
        },
        silly_client::RequestHeader {
            name: "X-Test",
            value: "second"
        }];
    var result = silly_client::forward_request_headers(request, overrides);
    assert(result.error == silly_client::ClientError.None);
    assert(result.fields.len == 2);
    assert(silly_client::forward_header(result, 0).value == "first");
    assert(silly_client::forward_header(result, 1).value == "second");
    result = silly_client::forward_request_headers(request, [], silly_client::ForwardPolicy {
            authorization: silly_client::ProxyAuthorization.Incoming,
            host: silly_client::ProxyHost.Incoming,
            ..
        });
    assert(result.fields.len == 2);
    assert(silly_client::forward_header(result, 0).name == "Host");
    result = silly_client::forward_request_headers(request, [], silly_client::ForwardPolicy {
            authorization: silly_client::ProxyAuthorization.Override,
            authorization_value: "Bearer supplied",
            host: silly_client::ProxyHost.Override,
            host_value: "upstream",
            ..
        });
    assert(result.fields.len == 3);
    assert(silly_client::forward_header(result, 1).value == "Bearer supplied");
    assert(silly_client::forward_header(result, 2).value == "upstream");
}

fn responses() {
    var response = silly_client::parse_client_response(
        str("HTTP/1.1 200 OK\r\nConnection: X-Hop\r\nX-Hop: no\r\nContent-Length: 2\r\n",
        "Set-Cookie: a=1\r\nSet-Cookie: b=2\r\nContent-Encoding: gzip\r\n\r\n"), 200);
    var result = silly_client::forward_response_headers(response);
    assert(result.error == silly_client::ClientError.None);
    assert(result.fields.len == 3);
    assert(silly_client::forward_header(result, 0).value == "a=1");
    assert(silly_client::forward_header(result, 1).value == "b=2");
    assert(silly_client::forward_header(result, 2).value == "gzip");
    response.fields[0].name_start = -1;
    assert(silly_client::forward_response_headers(response).error == silly_client::ClientError.Invalid);
}

fn invalid_and_limits() {
    var value: u8[>..] = [];
    value.resize(4097, 'a');
    let fields = [silly::HeaderView {
            name: "Connection",
            value: value
        }];
    let request = silly::Request {
        method: "GET",
        target: "/",
        headers: fields,
        ..
    };
    assert(silly_client::forward_request_headers(request, []).error == silly_client::ClientError.Limit);
    let bad_fields = [silly::HeaderView {
            name: "Connection",
            value: "x, bad name"
        }];
    let bad = silly::Request {
        method: "GET",
        target: "/",
        headers: bad_fields,
        ..
    };
    assert(silly_client::forward_request_headers(bad, []).error == silly_client::ClientError.Invalid);
    let empty = silly::Request {
        method: "GET",
        target: "/",
        ..
    };
    let overrides = [silly_client::RequestHeader {
            name: "Content-Length",
            value: "1"
        }];
    assert(silly_client::forward_request_headers(empty, overrides).error == silly_client::ClientError.Invalid);
}

fn targets() {
    var output: u8[>..] = [];
    assert(silly_client::proxy_target(output, "https://example.test/base/", "/path", "x=1&x=2")
        == silly_client::ClientError.None);
    assert(output == "https://example.test/base/path?x=1&x=2");
    output.clear();
    assert(silly_client::proxy_target(output, "http://", "/path") == silly_client::ClientError.Invalid);
    assert(output.len == 0);
    assert(silly_client::proxy_target(output, "http://example.test", "/path", "a=\r\n")
        == silly_client::ClientError.Invalid);
    assert(output.len == 0);
}

fn::main() {
    proxy_headers_test::requests();
    proxy_headers_test::responses();
    proxy_headers_test::invalid_and_limits();
    proxy_headers_test::targets();
    print("proxy header policies, hop filtering and target composition passed");
}
