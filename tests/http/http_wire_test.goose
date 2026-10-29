// Real vectored wire writes exercise framing boundaries, backpressure and terminal failure.
namespace http_wire_test;

import silly from "../../";

import std;

fn frame_builders() {
    var bytes: u8[>..] = [];
    assert(silly::write_chunk_prefix(bytes, 0, 32) == silly::ResponseError.InvalidState);
    assert(bytes.len == 0);
    assert(silly::write_chunk_prefix(bytes, 9223372036854775807, 17) == silly::ResponseError.HeaderBytesLimit);
    assert(bytes.len == 0);
    assert(silly::write_chunk_prefix(bytes, 9223372036854775807, 18) == silly::ResponseError.None);
    assert(bytes == "7fffffffffffffff\r\n");
    assert(silly::write_chunk_end(bytes, 32) == silly::ResponseError.InvalidState);
    bytes.clear();
    assert(silly::write_chunk_end(bytes, 4) == silly::ResponseError.HeaderBytesLimit);
    assert(bytes.len == 0);
    assert(silly::write_chunk_end(bytes, 5) == silly::ResponseError.None);
    assert(bytes == "0\r\n\r\n");
}

fn send(socket: silly_transport::Descriptor, parts: silly::WireParts, budget: i64) {
    var cursor = silly::WireCursor {
    };
    var turns: i64 = 0;
    while cursor.status != silly::WireStatus.Complete {
        let result = silly::write_wire(socket, cursor, parts, budget);
        assert(result.status == silly::WireStatus.Progress || result.status == silly::WireStatus.Complete);
        assert(result.count > 0);
        assert(result.count <= budget);
        turns += 1;
        assert(turns <= parts.prefix.len + parts.payload.len + parts.suffix.len);
    }
    let repeated = silly::write_wire(socket, cursor, parts, budget);
    assert(repeated.status == silly::WireStatus.Complete);
    assert(repeated.count == 0);
}

fn receive(socket: silly_transport::Descriptor, expected: u8[:]) {
    var bytes: u8[>..] = [];
    bytes.resize(expected.len, 0);
    var offset: i64 = 0;
    while offset < bytes.len {
        let result = silly_transport::read(socket, bytes[offset..]);
        assert(result.status == silly_transport::IoStatus.Ready);
        assert(result.count > 0);
        offset += result.count;
    }
    assert(bytes == expected);
}

fn boundaries() {
    for budget in 1..12 {
        var pair = silly_transport::wake_pair();
        assert(pair.status == silly_transport::IoStatus.Ready);
        var cursor = silly::WireCursor {
        };
        let parts = silly::WireParts {
            prefix: "4\r\n",
            payload: "a\x00bc",
            suffix: "\r\n"
        };
        assert(silly::write_wire(pair.writer, cursor, parts, 0).status == silly::WireStatus.Blocked);
        assert(cursor.prefix_sent == 0);
        send(pair.writer, parts, budget);
        receive(pair.reader, "4\r\na\x00bc\r\n");
        silly_transport::close(pair.reader);
        silly_transport::close(pair.writer);
    }
}

fn stream_wire(minor: i32) {
    var fields: silly::HeaderField[>..] = [];
    var metadata: u8[>..] = [];
    var output: u8[>..] = [];
    var head: u8[>..] = [];
    var response = silly::Response {
        limits: silly::Limits {
        },
        header_fields: fields,
        header_bytes: metadata,
        output: output,
        mode: silly::ResponseBodyMode.Stream,
        ..
    };
    assert(silly::begin_response(response, 200) == silly::ResponseError.None);
    assert(silly::prepare_response(response) == silly::ResponseError.None);
    let plan = silly::prepare_response_head(head, response, silly::ResponseWireOptions {
            http_minor: minor,
            ..
        }, 512);
    assert(plan.error == silly::ResponseError.None);
    var pair = silly_transport::wake_pair();
    assert(pair.status == silly_transport::IoStatus.Ready);
    send(pair.writer, silly::WireParts {
            prefix: head,
            ..
        }, 3);
    if minor == 1 {
        var prefix: u8[>..] = [];
        assert(silly::write_chunk_prefix(prefix, 4, 32) == silly::ResponseError.None);
        send(pair.writer, silly::WireParts {
                prefix: prefix,
                payload: "a\x00bc",
                suffix: "\r\n"
            }, 2);
        prefix.clear();
        assert(silly::write_chunk_end(prefix, 32) == silly::ResponseError.None);
        send(pair.writer, silly::WireParts {
                prefix: prefix,
                ..
            }, 1);
        receive(pair.reader,
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n4\r\na\x00bc\r\n0\r\n\r\n");
    } else {
        send(pair.writer, silly::WireParts {
                payload: "a\x00bc",
                ..
            }, 2);
        receive(pair.reader, "HTTP/1.0 200 OK\r\nConnection: close\r\n\r\na\x00bc");
    }
    silly_transport::close(pair.writer);
    var scratch: u8[1] = [0];
    assert(silly_transport::read(pair.reader, scratch).status == silly_transport::IoStatus.Closed);
    silly_transport::close(pair.reader);
}

fn failures() {
    var cursor = silly::WireCursor {
        prefix_sent: 2,
        ..
    };
    let parts = silly::WireParts {
        prefix: "x",
        ..
    };
    let socket = silly_transport::Descriptor {
    };
    assert(silly::write_wire(socket, cursor, parts, 1).status == silly::WireStatus.InvalidState);
    assert(silly::write_wire(socket, cursor, parts, 1).count == 0);
    var empty = silly::WireCursor {
    };
    assert(silly::write_wire(socket, empty, silly::WireParts {
        }, 0).status == silly::WireStatus.Complete);
    var pair = silly_transport::wake_pair();
    assert(pair.status == silly_transport::IoStatus.Ready);
    silly_transport::close(pair.reader);
    var failed = silly::WireCursor {
    };
    let result = silly::write_wire(pair.writer, failed, parts, 1);
    assert(result.status == silly::WireStatus.Failed);
    assert(result.system_error != 0);
    assert(failed.prefix_sent == 0);
    let repeated = silly::write_wire(pair.writer, failed, parts, 1);
    assert(repeated.status == silly::WireStatus.Failed);
    assert(repeated.count == 0);
    assert(repeated.system_error == result.system_error);
    silly_transport::close(pair.writer);
}

fn backpressure() {
    var pair = silly_transport::wake_pair();
    assert(pair.status == silly_transport::IoStatus.Ready);
    var payload: u8[>..] = [];
    payload.resize(2 * 1024 * 1024, 'x');
    let parts = silly::WireParts {
        prefix: "p",
        payload: payload,
        suffix: "s"
    };
    var cursor = silly::WireCursor {
    };
    var turns: i64 = 0;
    while cursor.status != silly::WireStatus.Blocked {
        let result = silly::write_wire(pair.writer, cursor, parts, 65536);
        assert(result.status == silly::WireStatus.Progress || result.status == silly::WireStatus.Blocked);
        turns += 1;
        assert(turns < 4096);
    }
    let stopped = cursor.payload_sent;
    assert(silly::write_wire(pair.writer, cursor, parts, 65536).status == silly::WireStatus.Blocked);
    assert(cursor.payload_sent == stopped);
    var read_bytes: i64 = 0;
    var scratch: u8[4096] = [0; 4096];
    while cursor.status != silly::WireStatus.Complete || read_bytes < payload.len + 2 {
        if cursor.status != silly::WireStatus.Complete {
            let sent = silly::write_wire(pair.writer, cursor, parts, 65536);
            assert(sent.status == silly::WireStatus.Progress || sent.status == silly::WireStatus.Blocked
                || sent.status == silly::WireStatus.Complete || sent.status == silly::WireStatus.Interrupted);
        }
        let received = silly_transport::read(pair.reader, scratch);
        if received.status == silly_transport::IoStatus.Ready {
            for index in received.count {
                let offset = read_bytes + index;
                let expected = if offset == 0 {
                    'p'
                } else if offset == payload.len + 1 {
                    's'
                } else {
                    'x'
                };
                assert(scratch[index] == expected);
            }
            read_bytes += received.count;
        } else {
            assert(received.status == silly_transport::IoStatus.WouldBlock
                || received.status == silly_transport::IoStatus.Interrupted);
        }
        turns += 1;
        assert(turns < 20000);
    }
    assert(cursor.prefix_sent == 1);
    assert(cursor.payload_sent == payload.len);
    assert(cursor.suffix_sent == 1);
    silly_transport::close(pair.reader);
    silly_transport::close(pair.writer);
}

fn::main() {
    http_wire_test::frame_builders();
    http_wire_test::boundaries();
    http_wire_test::stream_wire(0);
    http_wire_test::stream_wire(1);
    http_wire_test::failures();
    http_wire_test::backpressure();
    print("separate response wire segments passed");
}
