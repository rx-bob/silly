// Owned response metadata and body access preserve typed client outcomes.
namespace client_response_test;

import client from "../client";
import response from "../client";

import std;

fn normalized() {
    let raw = str("HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nX-Repeat: one\r\n",
        "x-repeat: two\r\nTransfer-Encoding: chunked\r\nContent-Encoding: gzip\r\nContent-Length: 27\r\nTrailer: X-Trailer\r\nEmpty:\r\n\r\n");
    var original = silly_client::parse_client_response(raw, 200);
    assert(original.ok);
    assert(original.ready);
    assert(original.fields.len == 5);
    assert(!silly_client::get_header(original, "content-length").present);
    assert(!silly_client::get_header(original, "trailer").present);
    assert(silly_client::get_header(original, "content-type").value == "application/octet-stream");
    assert(silly_client::get_header(original, "empty").present);
    assert(silly_client::get_header(original, "empty").value.len == 0);
    assert(!silly_client::get_header(original, "missing").present);
    assert(!silly_client::get_header(original, "transfer-encoding").present);
    assert(silly_client::response_header(original, 1).value == "one");
    assert(silly_client::response_header(original, 2).value == "two");
    var decoded = silly_client::parse_client_response(raw, 200, true);
    assert(decoded.ok);
    assert(decoded.fields.len == 4);
    assert(!silly_client::get_header(decoded, "Content-Encoding").present);
    assert(!silly_client::get_header(decoded, "Content-Length").present);
    var head = silly_client::parse_client_response(raw, 200, true, true);
    assert(head.ok);
    assert(head.kind == silly_client::ResponseKind.Bodyless);
    assert(silly_client::get_header(head, "Content-Encoding").value == "gzip");
    assert(silly_client::get_header(head, "Content-Length").value == "27");
}

fn failures() {
    for raw in["", "HTTP/1.1 200 OK\r\nX: y\r\n", "HTTP/1.1 200 OK\r\nBad Name: x\r\n\r\n",
        "HTTP/1.1 200 OK\r\n Folded: x\r\n\r\n", "HTTP/1.1 200 OK\r\nX: a\0b\r\n\r\n",
        "HTTP/1.1 200 OK\r\n\r\nX-Trailer: ignored\r\n", "HTTP/1.1 201 Created\r\n\r\n"] {
        let head = silly_client::parse_client_response(raw, 200);
        assert(!head.ok);
        assert(head.error == silly_client::ClientError.Protocol);
    }
    var many: u8[>..] = [];
    many.append("HTTP/1.1 200 OK\r\n");
    for index in 129 {
        many.append("X: a\r\n");
    }
    many.append("\r\n");
    assert(silly_client::parse_client_response(many, 200).error == silly_client::ClientError.Limit);
    var huge: u8[>..] = [];
    for index in 16385 {
        huge.push('x');
    }
    assert(silly_client::parse_client_response(huge, 200).error == silly_client::ClientError.Limit);
}

fn classifications() {
    var redirect = silly_client::parse_client_response("HTTP/1.1 302 Found\r\nLocation: /next\r\n\r\n", 302);
    assert(redirect.ok);
    assert(redirect.kind == silly_client::ResponseKind.Redirect);
    assert(silly_client::get_header(redirect, "location").value == "/next");
    var cached = silly_client::parse_client_response("HTTP/1.1 304 Not Modified\r\nContent-Length: 99\r\n\r\n",
        304, false, true);
    assert(cached.ok);
    assert(cached.kind == silly_client::ResponseKind.Bodyless);
    assert(silly_client::get_header(cached, "Content-Length").value == "99");
}

fn::main() {
    client_response_test::normalized();
    client_response_test::failures();
    client_response_test::classifications();
    print("client final-header ownership and normalization passed");
}
