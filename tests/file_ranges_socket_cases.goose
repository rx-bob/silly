// Socket assertions verify byte ranges, multipart framing and conditional responses.
namespace range_cases;

import silly from "..";

import std;

import.body_socket_fixture;
import.connection_socket_fixture;
import.file_ranges_socket_checks;

fn single(port: i32) {
    range_checks::basic(range_checks::range_get(port, "bytes=0-0"), 206, "<", "bytes 0-0/8");
    range_checks::basic(range_checks::range_get(port, "bytes=2-4"), 206, ">x<", "bytes 2-4/8");
    range_checks::basic(range_checks::range_get(port, "bytes=5-"), 206, "/p>", "bytes 5-7/8");
    range_checks::basic(range_checks::range_get(port, "bytes=-3"), 206, "/p>", "bytes 5-7/8");
    range_checks::basic(range_checks::range_get(port, "bytes=-99"), 206, "<p>x</p>", "bytes 0-7/8");
    range_checks::basic(range_checks::range_get(port, "bytes=0-99"), 206, "<p>x</p>", "bytes 0-7/8");
    range_checks::basic(range_checks::range_get(port, "bytes=99-,2-3"), 206, ">x", "bytes 2-3/8");
    for value in["bytes=8-", "bytes=99-100", "bytes=-0"] {
        range_checks::basic(range_checks::range_get(port, value), 416, "", "bytes */8");
    }
    let empty = range_checks::exchange(port, "GET", "/empty.txt", "Range: bytes=0-0\r\n");
    range_checks::basic(empty, 416, "", "bytes */0");
    const bytes: u8[2] = [255, 1];
    range_checks::basic(range_checks::exchange(port, "GET", "/opaque.bin", "Range: bytes=1-2\r\n"),
        206, bytes, "bytes 1-2/4");
}

fn ignored(port: i32) {
    for value in["items=0-1", "bytes=2-1", "bytes=", "bytes=one-two", "bytes=0-1,garbage",
        "bytes=9223372036854775808-", "bytes=-9223372036854775808", "bytes=0-9223372036854775808"] {
        range_checks::basic(range_checks::range_get(port, value), 200, "<p>x</p>");
    }
    var many: u8[>..] = [];
    many.append("bytes=0-0");
    for index in 16 {
        many.append(",0-0");
    }
    range_checks::basic(range_checks::range_get(port, many), 200, "<p>x</p>");
    var oversized: u8[>..] = [];
    oversized.append("bytes=0-");
    for index in 4096 {
        oversized.push('0');
    }
    range_checks::basic(range_checks::range_get(port, oversized), 200, "<p>x</p>");
    for path in["/disabled.html", "/limited.html"] {
        let response = range_checks::exchange(port, "GET", path, "Range: bytes=0-1,4-5\r\n");
        range_checks::basic(response, 200, "<p>x</p>");
    }
    let duplicate = range_checks::exchange(port, "GET", "/index.html", "Range: bytes=0-1\r\nRange: bytes=4-5\r\n");
    range_checks::basic(duplicate, 200, "<p>x</p>");
    let post = range_checks::exchange(port, "POST", "/index.html", "Range: bytes=0-1\r\n");
    range_checks::basic(post, 200, "<p>x</p>");
}

fn multipart(port: i32) {
    range_checks::multipart(range_checks::range_get(port, "bytes=0-1,5-7"), ["0-1", "5-7"], ["<p", "/p>"]);
    // Preserve overlap and request order, including repeated selected bytes.
    range_checks::multipart(range_checks::range_get(port, "bytes=3-5,0-3,3-5"),
        ["3-5", "0-3", "3-5"], ["x</", "<p>x", "x</"]);
    range_checks::multipart(range_checks::range_get(port, "bytes=99-,0-0,-1"), ["0-0", "7-7"], ["<", ">"]);
    let head = range_checks::exchange(port, "HEAD", "/index.html", "Range: bytes=0-1,5-7\r\n");
    range_checks::basic(head, 200, "", "", 8);
    assert(find(head, "Content-Type: text/html; charset=utf-8\r\n") >= 0);
    let unsatisfied = range_checks::exchange(port, "HEAD", "/index.html", "Range: bytes=99-\r\n");
    range_checks::basic(unsatisfied, 200, "", "", 8);
}

fn conditions(port: i32) {
    let cached = range_checks::exchange(port, "GET", "/index.html",
        "Range: bytes=99-\r\nIf-None-Match: W/\"range-8\"\r\n");
    range_checks::basic(cached, 304, "", "", 8);
    let dated = range_checks::exchange(port, "GET", "/index.html",
        "Range: bytes=0-1\r\nIf-Modified-Since: Sun, 06 Nov 1994 08:49:37 GMT\r\n");
    range_checks::basic(dated, 304, "", "", 8);
    let fresh = range_checks::exchange(port, "GET", "/index.html",
        "Range: bytes=0-1\r\nIf-None-Match: \"different\"\r\n");
    range_checks::basic(fresh, 206, "<p", "bytes 0-1/8");
    for validator in["\"range-8\"", "Sun, 06 Nov 1994 08:49:37 GMT"] {
        let response = range_checks::exchange(port, "GET", "/index.html",
            str("Range: bytes=0-1\r\nIf-Range: ", validator, "\r\n"));
        range_checks::basic(response, 206, "<p", "bytes 0-1/8");
    }
    for validator in["W/\"range-8\"", "\"different\"", "bad", "Sat, 05 Nov 1994 08:49:37 GMT",
        "Mon, 07 Nov 1994 08:49:37 GMT"] {
        let response = range_checks::exchange(port, "GET", "/index.html",
            str("Range: bytes=0-1\r\nIf-Range: ", validator, "\r\n"));
        range_checks::basic(response, 200, "<p>x</p>");
    }
    let duplicate = range_checks::exchange(port, "GET", "/index.html",
        "Range: bytes=0-1\r\nIf-Range: \"range-8\"\r\nIf-Range: \"range-8\"\r\n");
    range_checks::basic(duplicate, 200, "<p>x</p>");
    let weak_date = range_checks::exchange(port, "GET", "/default.txt",
        "Range: bytes=0-1\r\nIf-Range: Sun, 06 Nov 1994 08:49:37 GMT\r\n");
    range_checks::basic(weak_date, 200, "default!\n");
}

fn persistent(port: i32) {
    var socket = body_socket::connect(port);
    var pipeline: u8[>..] = [];
    pipeline.append(connection_socket::request("GET", "/index.html", 1, "Range: bytes=0-1,5-7\r\n"));
    pipeline.append(connection_socket::request("HEAD", "/index.html", 1, "Range: bytes=0-1\r\n"));
    pipeline.append(connection_socket::request("GET", "/empty.txt", 1, "Range: bytes=-1\r\n"));
    pipeline.append(connection_socket::request("GET", "/index.html", 1, "Range: bytes=-2\r\nConnection: close\r\n"));
    body_socket::send_bytes(socket, pipeline);
    range_checks::multipart(connection_socket::receive(socket), ["0-1", "5-7"], ["<p", "/p>"]);
    range_checks::basic(connection_socket::receive(socket, true), 200, "", "", 8);
    range_checks::basic(connection_socket::receive(socket), 416, "", "bytes */0");
    range_checks::basic(connection_socket::receive(socket), 206, "p>", "bytes 6-7/8");
    connection_socket::closed(socket);
    silly_transport::close(socket);
}
