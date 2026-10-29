// Read one framed response without consuming bytes belonging to the next response.
namespace connection_socket;

import silly from "../../../";

import std;

import.body_socket_fixture;

fn byte(socket: silly_transport::Descriptor) -> u8 {
    let deadline = body_socket::now() + 10000;
    var input: u8[1] = [0];
    while body_socket::now() < deadline {
        let result = silly_transport::read(socket, input);
        if result.status == silly_transport::IoStatus.Ready {
            assert(result.count == 1);
            return input[0];
        }
        if result.status == silly_transport::IoStatus.WouldBlock {
            body_socket::ready(socket, silly_transport::READ, deadline);
        } else {
            assert(result.status == silly_transport::IoStatus.Interrupted);
        }
    }
    abort("persistent response timed out");
}

fn receive(socket: silly_transport::Descriptor, head: bool = false) -> u8[>..] {
    var response: u8[>..] = [];
    while !ends_with(response, "\r\n\r\n") {
        assert(response.len < 2048);
        response.push(byte(socket));
    }
    var length: i64 = 0;
    let field = find(response, "Content-Length: ");
    if field >= 0 && !head {
        var cursor = field + 16;
        while response[cursor] != '\r' {
            assert(response[cursor] >= '0');
            assert(response[cursor] <= '9');
            length = length * 10 + (response[cursor] - '0');
            assert(length <= 2048);
            cursor += 1;
        }
    }
    for index in length {
        response.push(byte(socket));
    }
    return response;
}

fn exact(response: u8[:], minor: i32, status: i32, payload: u8[:]) {
    assert(starts_with(response, str("HTTP/1.", minor, " ", status, " ")));
    let end = find(response, "\r\n\r\n");
    assert(end >= 0);
    assert(response[end + 4..] == payload);
}

fn closed(socket: silly_transport::Descriptor) {
    let remaining = body_socket::receive_closed(socket);
    assert(remaining.len == 0);
}

fn request(method: u8[:], path: u8[:], minor: i32 = 1, fields: u8[:] = "", body: u8[:] = "") -> u8[>..] {
    return str(method, " ", path, " HTTP/1.", minor, "\r\nHost: localhost\r\n", fields,
        "Content-Length: ", body.len, "\r\n\r\n", body);
}
