// Fixed connection descriptors. Slabs are driver-owned; only lengths/offsets survive a turn.
namespace silly;

import.body_types;
import.http_head_types;
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
