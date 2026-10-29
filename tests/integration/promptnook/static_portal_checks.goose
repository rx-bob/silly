// Shared static response checks retain wire metadata and bounded body comparisons.
namespace portal_checks;

import silly from "../../../";

import std;

import.body_socket_fixture;
import.connection_socket_fixture;

const GZIP: u8[33] = [31, 139, 8, 0, 0, 0, 0, 0, 2, 255, 203, 72, 205, 201, 201, 87, 40,
    200, 47, 42, 73, 204, 225, 2, 0, 233, 29, 193, 18, 13, 0, 0, 0];
const IDENTITY = "hello portal\n";

fn exchange(port: i32, method: u8[:], path: u8[:], fields: u8[:] = "") -> u8[>..] {
    var socket = body_socket::connect(port);
    body_socket::send_bytes(socket, connection_socket::request(method, path, 1,
        str(fields, "Connection: close\r\n")));
    let result = body_socket::receive_closed(socket);
    silly_transport::close(socket);
    return result;
}

fn body(response: u8[:]) -> u8[:] {
    let at = find(response, "\r\n\r\n");
    assert(at >= 0);
    return response[at + 4..];
}

fn status(response: u8[:], code: i32) {
    assert(starts_with(response, str("HTTP/1.1 ", code, " ")));
}

fn file(response: u8[:], gzip: bool, payload: u8[:], code: i32 = 200, length: i64 = -1) {
    status(response, code);
    assert(body(response) == payload);
    let size = if length < 0 {
        payload.len
    } else {
        length
    };
    assert(find(response, str("Content-Length: ", size, "\r\n")) >= 0);
    assert(find(response, "Content-Type: text/plain; charset=utf-8\r\n") >= 0);
    assert(find(response, "Vary: Accept-Encoding\r\n") >= 0);
    assert((find(response, "Content-Encoding: gzip\r\n") >= 0) == gzip);
    assert(find(response, str("ETag: \"portal-", if gzip {
            33
        } else {
            13
        }, "\"\r\n")) >= 0);
    assert(find(response, "Transfer-Encoding:") < 0);
}
