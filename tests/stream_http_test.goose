// Bounded generated upload/echo, framing synchronization, and terminal input failures.
namespace stream_http_test;

import silly from "..";

import std;

import.body_socket_fixture;
import.connection_socket_fixture;
import.stream_http_fixture;

extern fn silly_stream_shutdown_write(fd: i32) -> i32;

extern fn silly_stream_reset(fd: i32) -> i32;

fn began(route: stream_http::Route) {
    let item, present = qget<stream_http::Began>(10000);
    assert(present);
    assert(item.route == route);
}

fn released(bytes: i64, cancelled: bool) -> stream_http::Released {
    let item, present = qget<stream_http::Released>(10000);
    assert(present);
    assert(item.bytes == bytes);
    assert(item.cancelled == cancelled);
    return item;
}

fn finished() -> silly::CompletionData {
    let item, present = qget<stream_http::Finished>(10000);
    assert(present);
    return item.data;
}

fn head(socket: silly_transport::Descriptor) -> u8[>..] {
    var result: u8[>..] = [];
    while !ends_with(result, "\r\n\r\n") {
        assert(result.len < 512);
        result.push(connection_socket::byte(socket));
    }
    return result;
}

fn pattern(offset: i64) -> u8 {
    return (offset % 251)as u8;
}

fn decode_to(socket: silly_transport::Descriptor, reader: silly::BodyReader&, target: i64) {
    while reader.decoded_bytes < target {
        var input: u8[1] = [connection_socket::byte(socket)];
        var output: u8[1] = [0];
        let offset = reader.decoded_bytes;
        let result = silly::read_body(reader, input, output, 1);
        assert(result.consumed == 1);
        assert(result.status == silly::BodyStatus.NeedInput || result.status == silly::BodyStatus.Progress);
        if result.produced > 0 {
            assert(output[0] == pattern(offset));
        }
    }
}

fn decode_end(socket: silly_transport::Descriptor, reader: silly::BodyReader&) {
    while reader.status != silly::BodyStatus.Complete {
        var input: u8[1] = [connection_socket::byte(socket)];
        var output: u8[1] = [0];
        let result = silly::read_body(reader, input, output, 1);
        assert(result.consumed == 1);
        assert(result.produced == 0);
        assert(result.status == silly::BodyStatus.Complete || result.status == silly::BodyStatus.NeedInput);
    }
}

fn upload(socket: silly_transport::Descriptor, total: i64, chunked: bool) {
    var reader = silly::new_body_reader(silly::BodyFraming.Chunked, 0,
        silly::BodyLimits {
            bytes_max: total,
            ..
        });
    var sent: i64 = 0;
    var bytes: u8[251] = [0; 251];
    while sent < total {
        let count = min(bytes.len, total - sent);
        for index in count {
            bytes[index] = pattern(sent + index);
        }
        if chunked {
            var prefix: u8[>..] = [];
            assert(silly::write_chunk_prefix(prefix, count, 18) == silly::ResponseError.None);
            body_socket::send_bytes(socket, prefix);
        }
        body_socket::send_bytes(socket, bytes[..count]);
        if chunked {
            body_socket::send_bytes(socket, "\r\n");
        }
        if sent == 0 {
            let headers = head(socket);
            assert(starts_with(headers, "HTTP/1.1 200 "));
            assert(find(headers, "Transfer-Encoding: chunked\r\n") >= 0);
        }
        sent += count;
        decode_to(socket, reader, sent);
    }
    if chunked {
        body_socket::send_bytes(socket, "0\r\nX-Upload: done\r\n\r\n");
    }
    // Following request is deliberately pipelined before prior response terminator arrives.
    body_socket::send_bytes(socket, connection_socket::request("GET", "/health", 1, "Connection: close\r\n"));
    decode_end(socket, reader);
    assert(reader.decoded_bytes == total);
    connection_socket::exact(connection_socket::receive(socket), 1, 200, "ok");
    connection_socket::closed(socket);
}

fn generated(port: i32, chunked: bool) {
    var socket = body_socket::connect(port);
    let total: i64 = if chunked {
        32771
    } else {
        65537
    };
    let fields: u8[>..] = if chunked {
        "Transfer-Encoding: chunked\r\n"
    } else {
        str("Content-Length: ", total, "\r\n")
    };
    body_socket::send_bytes(socket, str("POST /echo HTTP/1.1\r\nHost: localhost\r\n", fields, "\r\n"));
    began(stream_http::Route.Echo);
    upload(socket, total, chunked);
    let release = released(total, false);
    assert(release.pieces >= total / 17);
    assert(!release.failed);
    assert(finished().transfer == silly::TransferOutcome.Delivered);
    assert(finished().status == 200);
    silly_transport::close(socket);
}

fn expectation(port: i32) {
    var socket = body_socket::connect(port);
    body_socket::send_bytes(socket,
        str("POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 3\r\n",
        "Expect: 100-continue\r\nConnection: close\r\n\r\n"));
    body_socket::interim(socket);
    began(stream_http::Route.Echo);
    body_socket::send_bytes(socket, "abc");
    let result = body_socket::receive_closed(socket);
    let split = find(result, "\r\n\r\n");
    assert(split > 0);
    assert(starts_with(result, "HTTP/1.1 200 "));
    assert(result[split + 4..] == "3\r\nabc\r\n0\r\n\r\n");
    released(3, false);
    assert(finished().transfer == silly::TransferOutcome.Delivered);
    silly_transport::close(socket);
}

fn failed_before_output(port: i32, truncated: bool) {
    var socket = body_socket::connect(port);
    let fields = if truncated {
        "Content-Length: 4\r\n"
    } else {
        "Transfer-Encoding: chunked\r\n"
    };
    body_socket::send_bytes(socket, str("POST /echo HTTP/1.1\r\nHost: localhost\r\n", fields, "\r\n"));
    began(stream_http::Route.Echo);
    if truncated {
        assert(silly_stream_shutdown_write(socket.fd) == 0);
    } else {
        body_socket::send_bytes(socket, "z\r\n");
    }
    let response = body_socket::receive_closed(socket);
    assert(starts_with(response, "HTTP/1.1 400 "));
    assert(released(0, true).failed);
    assert(finished().status == 400);
    silly_transport::close(socket);
}

fn broken(port: i32, chunked: bool, truncated: bool) {
    var socket = body_socket::connect(port);
    let fields: u8[>..] = if chunked {
        "Transfer-Encoding: chunked\r\n"
    } else {
        "Content-Length: 4\r\n"
    };
    body_socket::send_bytes(socket, str("POST /echo HTTP/1.1\r\nHost: localhost\r\n", fields, "\r\n"));
    began(stream_http::Route.Echo);
    if chunked {
        body_socket::send_bytes(socket, "3\r\nabc\r\n");
    } else {
        body_socket::send_bytes(socket, "abc");
    }
    let headers = head(socket);
    assert(starts_with(headers, "HTTP/1.1 200 "));
    var echoed: u8[8] = [0; 8];
    for index in echoed.len {
        echoed[index] = connection_socket::byte(socket);
    }
    assert(echoed == "3\r\nabc\r\n");
    if truncated {
        assert(silly_stream_shutdown_write(socket.fd) == 0);
    } else {
        body_socket::send_bytes(socket, "z\r\n");
    }
    let tail = body_socket::receive_closed(socket);
    assert(find(tail, "HTTP/1.") < 0);
    assert(find(tail, "0\r\n\r\n") < 0);
    assert(released(3, true).failed);
    assert(finished().transfer == silly::TransferOutcome.Cancelled);
    silly_transport::close(socket);
}

fn early_and_limit(port: i32) {
    var early = body_socket::connect(port);
    body_socket::send_bytes(early,
        "POST /early HTTP/1.1\r\nHost: localhost\r\nContent-Length: 100\r\n\r\n");
    began(stream_http::Route.Early);
    let result = body_socket::receive_closed(early);
    assert(starts_with(result, "HTTP/1.1 200 "));
    assert(ends_with(result, "0\r\n\r\n"));
    released(0, false);
    assert(finished().transfer == silly::TransferOutcome.Delivered);
    silly_transport::close(early);
    body_socket::rejected(port,
        "POST /limit HTTP/1.1\r\nHost: localhost\r\nContent-Length: 14\r\nExpect: 100-continue\r\n\r\n", 413);
    assert(finished().status == 413);
    let item, selected = qpoll<stream_http::Began>();
    assert(!selected);
}

fn chunked_limit(port: i32) {
    var socket = body_socket::connect(port);
    body_socket::send_bytes(socket,
        "POST /limit HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n");
    began(stream_http::Route.Limit);
    body_socket::send_bytes(socket, "3\r\nabc\r\n");
    assert(starts_with(head(socket), "HTTP/1.1 200 "));
    var echoed: u8[8] = [0; 8];
    for index in echoed.len {
        echoed[index] = connection_socket::byte(socket);
    }
    assert(echoed == "3\r\nabc\r\n");
    body_socket::send_bytes(socket, "b\r\n");
    let tail = body_socket::receive_closed(socket);
    assert(tail.len == 0);
    assert(released(3, true).failed);
    assert(finished().transfer == silly::TransferOutcome.Cancelled);
    silly_transport::close(socket);
}

fn buffered_early(port: i32) {
    var socket = body_socket::connect(port);
    body_socket::send_bytes(socket,
        "POST /buffered HTTP/1.1\r\nHost: localhost\r\nContent-Length: 100\r\n\r\n");
    let response = body_socket::receive_closed(socket);
    connection_socket::exact(response, 1, 200, "ok");
    assert(find(response, "Connection: close\r\n") >= 0);
    assert(finished().transfer == silly::TransferOutcome.Delivered);
    let extra, has_extra = qpoll<stream_http::Released>();
    assert(!has_extra);
    silly_transport::close(socket);
}

fn disconnected(port: i32) {
    var socket = body_socket::connect(port);
    body_socket::send_bytes(socket,
        "POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 100\r\n\r\n");
    began(stream_http::Route.Echo);
    assert(silly_stream_reset(socket.fd) == 0);
    silly_transport::close(socket);
    released(0, true);
    assert(finished().transfer == silly::TransferOutcome.Cancelled);
}

fn cancelled(port: i32, wake: silly_transport::Descriptor) {
    var socket = body_socket::connect(port);
    body_socket::send_bytes(socket, "POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 100\r\n\r\n");
    began(stream_http::Route.Echo);
    assert(silly_transport::notify(wake).status == silly_transport::IoStatus.Ready);
    released(0, true);
    assert(finished().transfer == silly::TransferOutcome.Cancelled);
    connection_socket::closed(socket);
    silly_transport::close(socket);
}

fn run() {
    qlimit<stream_http::Started>(1);
    qlimit<stream_http::Began>(8);
    qlimit<stream_http::Released>(8);
    qlimit<stream_http::Finished>(8);
    qlimit<stream_http::Stopped>(1);
    var listener = silly_transport::listen("127.0.0.1", 0, 8);
    assert(listener.status == silly_transport::IoStatus.Ready);
    let port = silly_transport::local_port(listener.descriptor);
    var wake = silly_transport::wake_pair();
    let worker = thread_spawn(stream_http::serve, listener.descriptor.fd, wake.reader.fd, 30000);
    listener.descriptor.fd = -1;
    wake.reader.fd = -1;
    let start, started = qget<stream_http::Started>(10000);
    assert(started);
    generated(port.count as i32, false);
    generated(port.count as i32, true);
    expectation(port.count as i32);
    failed_before_output(port.count as i32, false);
    failed_before_output(port.count as i32, true);
    broken(port.count as i32, true, false);
    broken(port.count as i32, false, true);
    broken(port.count as i32, true, true);
    early_and_limit(port.count as i32);
    chunked_limit(port.count as i32);
    buffered_early(port.count as i32);
    disconnected(port.count as i32);
    cancelled(port.count as i32, wake.writer);
    let stop, stopped = qget<stream_http::Stopped>(10000);
    assert(stopped);
    assert(stop.ok);
    assert(thread_wait(worker));
    let extra, duplicate = qpoll<stream_http::Released>();
    assert(!duplicate);
    silly_transport::close(wake.writer);
}

fn::main() {
    stream_http_test::run();
    print("incremental streamed HTTP input, reuse and cancellation passed");
}
