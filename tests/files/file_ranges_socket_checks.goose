// Socket assertions inspect framing and bytes independently of the range implementation.
namespace range_checks;

import silly from "../../";

import std;

import.body_socket_fixture;
import.connection_socket_fixture;

fn exchange(port: i32, method: u8[:], path: u8[:], fields: u8[:]) -> u8[>..] {
    var socket = body_socket::connect(port);
    body_socket::send_bytes(socket, connection_socket::request(method, path, 1,
        str(fields, "Connection: close\r\n")));
    let result = body_socket::receive_closed(socket);
    silly_transport::close(socket);
    return result;
}

fn basic(response: u8[:], status: i32, body: u8[:], range: u8[:] = "", length: i64 = -1) {
    connection_socket::exact(response, 1, status, body);
    let end = find(response, "\r\n\r\n");
    let head = response[..end + 2];
    let expected_length = if length >= 0 {
        length
    } else {
        body.len
    };
    assert(find(head, str("Content-Length: ", expected_length, "\r\n")) >= 0);
    assert(find(head, "Transfer-Encoding:") < 0);
    if status == 206 || status == 416 {
        assert(find(head, "Accept-Ranges: bytes\r\n") >= 0);
    }
    if range.len > 0 {
        assert(find(head, str("Content-Range: ", range, "\r\n")) >= 0);
    } else {
        assert(find(head, "Content-Range:") < 0);
    }
    assert(find(head, "Last-Modified: Sun, 06 Nov 1994 08:49:37 GMT\r\n") >= 0);
}

fn range_get(port: i32, value: u8[:]) -> u8[>..] {
    return exchange(port, "GET", "/index.html", str("Range: ", value, "\r\n"));
}

fn multipart(response: u8[:], selections: (const u8[:])[:], contents: (const u8[:])[:]) {
    assert(starts_with(response, "HTTP/1.1 206 "));
    let end = find(response, "\r\n\r\n");
    assert(end > 0);
    let head = response[..end + 2];
    let prefix = "Content-Type: multipart/byteranges; boundary=";
    let start = find(head, prefix);
    assert(start >= 0);
    assert(find(head, "Content-Type:") == start);
    let tail = head[start + prefix.len..];
    let line_end = find(tail, "\r\n");
    assert(line_end > 0);
    let boundary = tail[..line_end];
    assert(boundary.len <= 70);
    assert(find(head, "Content-Range:") < 0);
    assert(find(head[start + prefix.len..], "Content-Type:") < 0);
    assert(find(head, "Transfer-Encoding:") < 0);
    var expected: u8[>..] = [];
    for index in selections.len {
        expected.append(str("--", boundary, "\r\nContent-Type: text/html; charset=utf-8\r\n",
            "Content-Range: bytes ", selections[index], "/8\r\n\r\n", contents[index], "\r\n"));
    }
    expected.append(str("--", boundary, "--\r\n"));
    assert(find(head, str("Content-Length: ", expected.len, "\r\n")) >= 0);
    assert(response[end + 4..] == expected);
}
