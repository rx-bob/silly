// Socket cases for one application serving buffered pages and owned stream producers.
namespace general_web_cases;

import silly from "..";

import std;

import.body_socket_fixture;
import.connection_socket_fixture;
import.general_web_types;
import.lifecycle_native;

fn request(port: i32, method: u8[:], path: u8[:], body: u8[:] = "", media: u8[:] = "text/plain") -> u8[>..] {
    var socket = body_socket::connect(port);
    body_socket::send_bytes(socket, connection_socket::request(method, path, 1,
        str("Connection: close\r\nContent-Type: ", media, "\r\nLast-Event-ID: 41\r\n"), body));
    let result = body_socket::receive_closed(socket);
    silly_transport::close(socket);
    return result;
}

fn payload(response: u8[:], status: i32) -> u8[>..] {
    assert(starts_with(response, str("HTTP/1.1 ", status, " ")));
    let end = find(response, "\r\n\r\n");
    assert(end >= 0);
    let chunked = find(response[..end], "Transfer-Encoding: chunked") >= 0;
    var reader = silly::new_body_reader(if chunked {
            silly::BodyFraming.Chunked
        } else {
            silly::BodyFraming.Fixed
        },
        if chunked {
            0
        } else {
            response.len - end - 4
        }, silly::BodyLimits {
            bytes_max: 2048,
            ..
        });
    var bytes: u8[2048] = [0; 2048];
    let result = silly::read_body(reader, response[end + 4..], bytes, 4096);
    assert(result.status == silly::BodyStatus.Complete);
    assert(result.consumed == response.len - end - 4);
    var out: u8[>..] = [];
    out.append(bytes[..result.produced]);
    return out;
}

fn release(route: general_web::Route, cancelled: bool, bytes: i64 = 0, failed: bool = false) {
    if route != general_web::Route.File {
        let acquired, present = qget<general_web::Acquired>(10000);
        assert(present);
        assert(acquired.route == route);
        var peer = silly_transport::Descriptor {
            fd: acquired.peer
        };
        let released, ready = qget<general_web::Released>(10000);
        assert(ready);
        assert(released.route == route);
        assert(released.cancelled == cancelled);
        assert(released.bytes == bytes);
        assert(released.failed == failed);
        var scratch: u8[1] = [0];
        assert(silly_transport::read(peer, scratch).status == silly_transport::IoStatus.Closed);
        silly_transport::close(peer);
    } else {
        let released, ready = qget<general_web::Released>(10000);
        assert(ready);
        assert(released.route == route);
        assert(!released.cancelled);
    }
}

fn buffered(port: i32) {
    let page = request(port, "GET", "/");
    assert(find(page, "Content-Type: text/html; charset=utf-8") >= 0);
    assert(find(payload(page, 200), "<form action=\"/form\"") >= 0);
    let form = request(port, "POST", "/form", "name=%3CAda%3E%26", "application/x-www-form-urlencoded");
    assert(payload(form, 303).len == 0);
    assert(find(form, "Location: /\r\n") >= 0);
    assert(starts_with(payload(request(port, "GET", "/"), 200), "<h1>Hello &lt;Ada&gt;&amp;</h1>"));
    assert(payload(request(port, "POST", "/form", "name=", "application/x-www-form-urlencoded"), 400)
        == "Name is required");
    assert(payload(request(port, "POST", "/form", "name=x"), 415).len == 0);
    let json = request(port, "POST", "/json", "{\"name\":\"Ada\"}", "application/json");
    assert(find(json, "Content-Type: application/json") >= 0);
    assert(payload(json, 201) == "{\"name\":\"Ada\"}");
    assert(payload(request(port, "POST", "/json", "{bad}", "application/json"), 400).len == 0);
    var socket = body_socket::connect(port);
    body_socket::send_bytes(socket, str("POST /json HTTP/1.1\r\nHost: local\r\nConnection: close\r\n",
        "Content-Length: 129\r\nExpect: 100-continue\r\n\r\n"));
    assert(payload(body_socket::receive_closed(socket), 413).len == 0);
    silly_transport::close(socket);
}

fn streams(port: i32) {
    let archive = payload(request(port, "GET", "/file"), 200);
    assert(archive.len == 22);
    assert(archive[..4] == "PK\x05\x06");
    for byte in archive[4..] {
        assert(byte == 0);
    }
    release(general_web::Route.File, false);
    assert(payload(request(port, "GET", "/download"), 200) == "download\n");
    release(general_web::Route.Download, false);
    let events = request(port, "GET", "/events");
    assert(find(events, "Content-Type: text/event-stream") >= 0);
    assert(payload(events, 200) == "event: tick\nid: 41\ndata: ready\n\n");
    release(general_web::Route.Events, false);
    let large: u8[257] = ['x'; 257];
    assert(payload(request(port, "POST", "/upload", large), 200) == large);
    release(general_web::Route.Upload, false, 257);
    var socket = body_socket::connect(port);
    body_socket::send_bytes(socket, str("POST /upload HTTP/1.1\r\nHost: local\r\nConnection: close\r\n",
        "Transfer-Encoding: chunked\r\n\r\n3\r\na", "\x00", "b\r\n2\r\ncd\r\n0\r\n\r\n"));
    assert(payload(body_socket::receive_closed(socket), 200) == "a\x00bcd");
    silly_transport::close(socket);
    release(general_web::Route.Upload, false, 5);
}

fn disconnected(port: i32) {
    var socket = body_socket::connect(port);
    body_socket::send_bytes(socket, connection_socket::request("GET", "/waiting"));
    let waiting, ready = qget<general_web::Waiting>(10000);
    assert(ready);
    // Another route remains serviceable while an SSE producer waits.
    assert(find(payload(request(port, "GET", "/"), 200), "&lt;Ada&gt;") >= 0);
    assert(lifecycle_native::silly_lifecycle_reset_close(socket.fd) == 0);
    silly_transport::close(socket);
    release(general_web::Route.Waiting, true);
    let extra, leaked = qpoll<general_web::Released>();
    assert(!leaked);
}

fn upload_failures(port: i32) {
    var invalid = body_socket::connect(port);
    body_socket::send_bytes(invalid, str("POST /upload HTTP/1.1\r\nHost: local\r\n",
        "Transfer-Encoding: chunked\r\nConnection: close\r\n\r\nz\r\n"));
    assert(payload(body_socket::receive_closed(invalid), 400).len == 0);
    silly_transport::close(invalid);
    release(general_web::Route.Upload, true, 0, true);
    var oversized = body_socket::connect(port);
    body_socket::send_bytes(oversized, str("POST /upload HTTP/1.1\r\nHost: local\r\n",
        "Content-Length: 1025\r\nExpect: 100-continue\r\nConnection: close\r\n\r\n"));
    let response = body_socket::receive_closed(oversized);
    assert(payload(response, 413).len == 0);
    assert(find(response, "100 Continue") < 0);
    silly_transport::close(oversized);
    let acquired, unexpected = qpoll<general_web::Acquired>();
    assert(!unexpected);
}

fn event_limit(port: i32) {
    let id: u8[33] = ['x'; 33];
    var socket = body_socket::connect(port);
    body_socket::send_bytes(socket, connection_socket::request("GET", "/events", 1,
        str("Connection: close\r\nLast-Event-ID: ", id, "\r\n")));
    assert(payload(body_socket::receive_closed(socket), 413).len == 0);
    silly_transport::close(socket);
    let acquired, leaked = qpoll<general_web::Acquired>();
    assert(!leaked);
}
