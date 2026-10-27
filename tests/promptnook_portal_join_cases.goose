namespace portal_join_cases;

import silly from "..";

import std;

import.body_socket_fixture;
import.connection_socket_fixture;
import.promptnook_portal_app;
import.promptnook_portal_upstream;
import.static_portal_cases;
import.static_portal_checks;

fn begin(port: i32, path: u8[:]) -> silly_transport::Descriptor {
    let socket = body_socket::connect(port);
    body_socket::send_bytes(socket, str("GET ", path, " HTTP/1.1\r\nHost: portal.test\r\n",
        "Connection: close, X-Hop\r\nX-Hop: removed\r\n\r\n"));
    return socket;
}

fn proxy_reply(socket: silly_transport::Descriptor, expected: u8[:]) {
    let response = body_socket::receive_closed(socket);
    portal_checks::status(response, 201);
    assert(find(response, "X-Upstream: fixture\r\n") >= 0);
    assert(find(response, "Transfer-Encoding: chunked\r\n") >= 0);
    let wire = portal_checks::body(response);
    var reader = silly::new_body_reader(silly::BodyFraming.Chunked, 0, silly::BodyLimits {
        });
    var body: u8[4096] = [0; 4096];
    let decoded = silly::read_body(reader, wire, body, 4096);
    assert(decoded.status == silly::BodyStatus.Complete);
    assert(decoded.consumed == wire.len);
    assert(body[..decoded.produced] == expected);
}

fn proxy(port: i32) {
    var socket = begin(port, "/portal-api/echo?environment=axiom&a=1&a=2");
    proxy_reply(socket, "GET /api/admin/echo?a=1&a=2");
    silly_transport::close(socket);
    socket = body_socket::connect(port);
    body_socket::send_bytes(socket, str("POST /portal-api/echo HTTP/1.1\r\nHost: portal.test\r\n",
        "Connection: close\r\nTransfer-Encoding: chunked\r\n\r\n5\r\n"));
    const body: u8[5] = ['a', 0, 255, '\r', '\n'];
    body_socket::send_bytes(socket, body);
    body_socket::send_bytes(socket, "\r\n0\r\n\r\n");
    proxy_reply(socket, "POST /api/admin/echo");
    silly_transport::close(socket);
}

fn waiting(port: i32, cancel: bool) {
    var socket = begin(port, "/portal-api/hold");
    let waiting, present = qget<portal_upstream::Holding>(10000);
    assert(present);
    // A held upstream cannot stall unrelated file work in this same Portal instance.
    portal_checks::file(portal_checks::exchange(port, "GET", "/asset.txt"), false, portal_checks::IDENTITY);
    if cancel {
        silly_transport::close(socket);
        let cancelled, received = qget<portal_integration::Cancelled>(10000);
        assert(received);
        assert(cancelled.proxy);
    }
    assert(qput(portal_upstream::Release {
        }));
    if !cancel {
        proxy_reply(socket, "GET /api/admin/hold");
        silly_transport::close(socket);
    }
}

fn failures(port: i32) {
    portal_checks::status(portal_checks::exchange(port, "GET", "/portal-api/echo?environment=missing"), 400);
    let refused = portal_checks::exchange(port, "GET", "/portal-api/echo?environment=refused");
    portal_checks::status(refused, 502);
    var socket = body_socket::connect(port);
    body_socket::send_bytes(socket, str("POST /portal-api/echo HTTP/1.1\r\nHost: portal.test\r\n",
        "Content-Length: 4097\r\nConnection: close\r\n\r\n"));
    portal_checks::status(body_socket::receive_closed(socket), 413);
    silly_transport::close(socket);
    // Still usable after policy failure, upstream failure, body rejection and cancellation.
    proxy(port);
}

fn run(port: i32) {
    portal_cases::metadata(port);
    portal_cases::compressed_multipart(port);
    portal_checks::file(portal_checks::exchange(port, "GET", "/asset.txt", "Accept-Encoding: gzip;q=0\r\n"),
        false, portal_checks::IDENTITY);
    let fallback = portal_checks::exchange(port, "GET", "/portal-apiary");
    portal_checks::status(fallback, 200);
    assert(find(fallback, "asset.txt") >= 0);
    portal_checks::status(portal_checks::exchange(port, "get", "/asset.txt"), 404);
    portal_checks::status(portal_checks::exchange(port, "head", "/asset.txt"), 404);
    proxy(port);
    waiting(port, false);
    waiting(port, true);
    failures(port);
}
