// Fixed connection descriptors. Slabs are driver-owned; only lengths/offsets survive a turn.
namespace silly;

import.body_types;
import.headers;
import.http_head_types;
import.http_headers;
import.transport;

enum ConnectionPhase {
    Free,
    Reading,
    ReadingBody,
    Continue,
    Writing,
}

struct Connection {
    socket: silly_transport::Descriptor = silly_transport::Descriptor {
    },
    generation: u64 = 0,
    phase: ConnectionPhase = ConnectionPhase.Free,
    scan: HeadScan = HeadScan {
    },
    input_bytes: i64 = 0,
    request_bytes: i64 = 0,
    staged_bytes: i64 = 0,
    staged_read: i64 = 0,
    received_bytes: i64 = 0,
    http_minor: i32 = 1,
    close_after_reply: bool = true,
    reader: BodyReader = BodyReader {
    },
    head_bytes: i64 = 0,
    body_bytes: i64 = 0,
    head_sent: i64 = 0,
    body_sent: i64 = 0,
    active_ms: i64 = 0,
}

fn release_connection(connection: Connection&) {
    silly_transport::close(connection.socket);
    connection.phase = ConnectionPhase.Free;
    // Generation never wraps: an exhausted slot is permanently unavailable.
}

fn available_connection(connections: Connection[:]) -> i64 {
    for index in connections.len {
        if connections[index].phase == ConnectionPhase.Free && connections[index].generation < 0xffffffffffffffff {
            return index;
        }
    }
    return -1;
}

// Only transport identity and bounded unread staging survive a completed response.
fn reset_connection(connection: Connection&) {
    let next = Connection {
        socket: connection.socket,
        generation: connection.generation,
        phase: ConnectionPhase.Reading,
        staged_bytes: connection.staged_bytes,
        staged_read: connection.staged_read,
        active_ms: connection.active_ms,
        ..
    };
    connection = next;
}

// Connection options are case insensitive; close always wins across repeated fields.
// Invalid token lists conservatively disable reuse.
fn request_persistent(fields: HeaderView[:], minor: i32) -> bool {
    var keep = minor == 1;
    var close = false;
    for field in fields {
        if !header_name_equal(field.name, "Connection") {
            continue;
        }
        var start: i64 = 0;
        for end in field.value.len + 1 {
            if end < field.value.len && field.value[end] != ',' {
                continue;
            }
            let token = trim_http_space(field.value[start..end]);
            if token.len != 0 {
                if !valid_header_name(token) || header_name_equal(token, "close") {
                    close = true;
                }
                if header_name_equal(token, "keep-alive") {
                    keep = true;
                }
            }
            start = end + 1;
        }
    }
    return keep && !close;
}
