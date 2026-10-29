// Portal static cases cover encoding, metadata, directories and persistent requests.
namespace portal_cases;

import silly from "../../../";

import std;

import.body_socket_fixture;
import.connection_socket_fixture;
import.static_portal_checks;

fn encoding(port: i32) {
    portal_checks::file(portal_checks::exchange(port, "GET", "/asset.txt"), false, portal_checks::IDENTITY);
    for value in["gzip", "GZip", "*;q=1", "gzip;q=1, identity;q=0", "gzip;q=0.8, identity;q=0.2"] {
        let response = portal_checks::exchange(port, "GET", "/asset.txt", str("Accept-Encoding: ", value, "\r\n"));
        portal_checks::file(response, true, portal_checks::GZIP);
    }
    for value in["gzip;q=0", "*;q=1, gzip;q=0", "gzip;q=0.2, identity;q=1", "", "gzip;q=bogus"] {
        let response = portal_checks::exchange(port, "GET", "/asset.txt", str("Accept-Encoding: ", value, "\r\n"));
        portal_checks::file(response, false, portal_checks::IDENTITY);
    }
    portal_checks::file(portal_checks::exchange(port, "GET", "/near.txt", "Accept-Encoding: gzip\r\n"),
        true, portal_checks::GZIP);
    for path in["/stale.txt", "/plain.txt", "/strict-near", "/edge.txt"] {
        portal_checks::file(portal_checks::exchange(port, "GET", path, "Accept-Encoding: gzip\r\n"),
            false, portal_checks::IDENTITY);
    }
    let unacceptable = portal_checks::exchange(port, "GET", "/stale.txt", "Accept-Encoding: gzip, identity;q=0\r\n");
    portal_checks::status(unacceptable, 406);
    portal_checks::status(portal_checks::exchange(port, "GET", "/asset.txt", "Accept-Encoding: *;q=0\r\n"), 406);
    portal_checks::file(portal_checks::exchange(port, "GET", "/asset.txt",
        "Accept-Encoding: gzip;q=0\r\nAccept-Encoding: *;q=1\r\n"), false, portal_checks::IDENTITY);
}

fn metadata(port: i32) {
    let head = portal_checks::exchange(port, "HEAD", "/asset.txt", "Accept-Encoding: gzip\r\n");
    portal_checks::file(head, true, "", 200, 33);
    assert(find(head, "Last-Modified: Sun, 06 Nov 1994 08:49:38 GMT\r\n") >= 0);
    let cached = portal_checks::exchange(port, "GET", "/asset.txt",
        "Accept-Encoding: gzip\r\nIf-None-Match: W/\"portal-33\"\r\n");
    portal_checks::file(cached, true, "", 304, 33);
    let other = portal_checks::exchange(port, "GET", "/asset.txt",
        "Accept-Encoding: gzip\r\nIf-None-Match: \"portal-13\"\r\n");
    portal_checks::file(other, true, portal_checks::GZIP);
    let ranged = portal_checks::exchange(port, "GET", "/asset.txt", "Accept-Encoding: gzip\r\nRange: bytes=2-5\r\n");
    portal_checks::file(ranged, true, portal_checks::GZIP[2..6], 206);
    assert(find(ranged, "Content-Range: bytes 2-5/33\r\n") >= 0);
    let failed = portal_checks::exchange(port, "GET", "/asset.txt",
        "Accept-Encoding: gzip\r\nRange: bytes=2-5\r\nIf-Range: \"portal-13\"\r\n");
    portal_checks::file(failed, true, portal_checks::GZIP);
}

fn compressed_multipart(port: i32) {
    let response = portal_checks::exchange(port, "GET", "/asset.txt",
        "Accept-Encoding: gzip\r\nRange: bytes=0-1,31-32\r\n");
    portal_checks::status(response, 206);
    let end = find(response, "\r\n\r\n");
    let headers = response[..end];
    assert(find(headers, "Content-Type: multipart/byteranges; boundary=") >= 0);
    assert(find(headers, "Content-Encoding:") < 0);
    assert(find(headers, "Content-Range:") < 0);
    assert(find(headers, "Vary: Accept-Encoding") >= 0);
    let at = find(headers, "boundary=");
    assert(at >= 0);
    var stop = at + 9;
    while stop < headers.len && headers[stop] != '\r' {
        stop += 1;
    }
    let boundary = headers[at + 9..stop];
    var expected: u8[>..] = [];
    expected.append(str("--", boundary, "\r\nContent-Type: text/plain; charset=utf-8\r\n",
        "Content-Range: bytes 0-1/33\r\nContent-Encoding: gzip\r\n\r\n"));
    expected.append(portal_checks::GZIP[..2]);
    expected.append(str("\r\n--", boundary, "\r\nContent-Type: text/plain; charset=utf-8\r\n",
        "Content-Range: bytes 31-32/33\r\nContent-Encoding: gzip\r\n\r\n"));
    expected.append(portal_checks::GZIP[31..]);
    expected.append(str("\r\n--", boundary, "--\r\n"));
    assert(portal_checks::body(response) == expected);
    assert(find(headers, str("Content-Length: ", expected.len)) >= 0);
}

fn listings(port: i32) {
    let root = portal_checks::exchange(port, "GET", "/");
    portal_checks::status(root, 200);
    let content = portal_checks::body(root);
    assert(find(content, "index.html") >= 0);
    assert(find(content, "<h1>spa</h1>") < 0);
    assert(find(content, "a.txt") < find(content, "z&lt;&gt;&amp;&quot;.txt"));
    assert(find(content, "z%3C%3E%26%22.txt") >= 0);
    assert(find(content, "z<>&\".txt") < 0);
    assert(find(content, "link") < 0);
    let missing = portal_checks::exchange(port, "GET", "/missing");
    portal_checks::status(missing, 200);
    assert(portal_checks::body(missing) == content);
    let slash_file = portal_checks::exchange(port, "GET", "/asset.txt/");
    portal_checks::status(slash_file, 200);
    assert(portal_checks::body(slash_file) == content);
    let denied = portal_checks::exchange(port, "GET", "/denied.txt");
    portal_checks::status(denied, 200);
    assert(portal_checks::body(denied) == content);
    let directory = portal_checks::exchange(port, "GET", "/sub/");
    portal_checks::status(directory, 200);
    assert(find(portal_checks::body(directory), "child.txt") >= 0);
    assert(find(portal_checks::body(directory), "index.html") < 0);
    let head = portal_checks::exchange(port, "HEAD", "/sub/");
    portal_checks::status(head, 200);
    assert(portal_checks::body(head).len == 0);
    assert(find(head, str("Content-Length: ", portal_checks::body(directory).len, "\r\n")) >= 0);
}

fn policies(port: i32) {
    for path in["/index/", "/spa-missing"] {
        let response = portal_checks::exchange(port, "GET", path);
        portal_checks::status(response, 200);
        assert(portal_checks::body(response) == "<h1>spa</h1>");
        assert(find(response, "Content-Type: text/html; charset=utf-8\r\n") >= 0);
    }
    portal_checks::status(portal_checks::exchange(port, "GET", "/reject"), 404);
    portal_checks::status(portal_checks::exchange(port, "POST", "/asset.txt"), 404);
    for path in["/loop", "/cap-entries", "/cap-output", "/cap-names"] {
        let response = portal_checks::exchange(port, "GET", path);
        portal_checks::status(response, 500);
    }
    for path in["/../etc/passwd", "/%2e%2e/etc/passwd", "/link"] {
        let response = portal_checks::exchange(port, "GET", path);
        assert(find(portal_checks::body(response), "root:") < 0);
    }
}

fn redirects(port: i32) {
    let response = portal_checks::exchange(port, "GET", "/sub?q=a%20b&x=%22");
    portal_checks::status(response, 302);
    assert(find(response, "Location: /sub/?q=a%20b&x=%22\r\n") >= 0);
    assert(portal_checks::body(response).len == 0);
    let escaped = portal_checks::exchange(port, "GET", "/space%20dir?next=%2Froot");
    portal_checks::status(escaped, 302);
    assert(find(escaped, "Location: /space%20dir/?next=%2Froot\r\n") >= 0);
}

fn persistent(port: i32) {
    var socket = body_socket::connect(port);
    var requests: u8[>..] = [];
    requests.append(connection_socket::request("GET", "/asset.txt", 1, "Accept-Encoding: gzip\r\n"));
    requests.append(connection_socket::request("HEAD", "/asset.txt", 1, "Accept-Encoding: gzip\r\n"));
    requests.append(connection_socket::request("GET", "/sub", 1, "Connection: close\r\n"));
    body_socket::send_bytes(socket, requests);
    portal_checks::file(connection_socket::receive(socket), true, portal_checks::GZIP);
    portal_checks::file(connection_socket::receive(socket, true), true, "", 200, 33);
    portal_checks::status(connection_socket::receive(socket), 302);
    connection_socket::closed(socket);
    silly_transport::close(socket);
}

fn concurrent_listing(port: i32) {
    var first = body_socket::connect(port);
    var second = body_socket::connect(port);
    let request = connection_socket::request("GET", "/", 1, "Connection: close\r\n");
    body_socket::send_bytes(first, request);
    body_socket::send_bytes(second, request);
    let left = body_socket::receive_closed(first);
    let right = body_socket::receive_closed(second);
    portal_checks::status(left, 200);
    portal_checks::status(right, 200);
    assert(find(portal_checks::body(left), "index.html") >= 0);
    assert(portal_checks::body(left) == portal_checks::body(right));
    silly_transport::close(first);
    silly_transport::close(second);
}

fn one_slot_fallback(port: i32) {
    let response = portal_checks::exchange(port, "GET", "/missing");
    portal_checks::status(response, 200);
    assert(find(portal_checks::body(response), "index.html") >= 0);
}
