// Bounded two-vector writes over stable, separate framing and payload owners.
namespace silly;

import std;

enum WireStatus {
    Progress,
    Complete,
    Blocked,
    Interrupted,
    InvalidState,
    Failed,
}
struct WireParts {
    prefix: const u8[:] = "",
    payload: const u8[:] = "",
    suffix: const u8[:] = "",
}
struct WireCursor {
    prefix_sent: i64 = 0,
    payload_sent: i64 = 0,
    suffix_sent: i64 = 0,
    status: WireStatus = WireStatus.Progress,
    system_error: i32 = 0,
}
struct WireWrite {
    status: WireStatus,
    count: i64 = 0,
    system_error: i32 = 0,
}
struct WireOffer {
    first: const u8[:],
    second: const u8[:],
}

// Keep the same bytes and lengths alive through completion. No slice is stored in the cursor.
fn write_wire(socket: silly_transport::Descriptor, cursor: WireCursor&, parts: WireParts,
    budget: i64) -> WireWrite {
    if wire_terminal(cursor.status) {
        return WireWrite {
            status: cursor.status,
            system_error: cursor.system_error,
            ..
        };
    }
    cursor.system_error = 0;
    if budget < 0 || !valid_wire_cursor(cursor, parts) {
        cursor.status = WireStatus.InvalidState;
    } else if wire_complete(cursor, parts) {
        cursor.status = WireStatus.Complete;
    } else if budget == 0 {
        cursor.status = WireStatus.Blocked;
    } else {
        let offer = wire_offer(cursor, parts, budget);
        let result = silly_transport::write_parts(socket, offer.first, offer.second);
        return apply_wire_write(cursor, parts, result, offer.first.len + offer.second.len);
    }
    return WireWrite {
        status: cursor.status,
        ..
    };
}

fn apply_wire_write(cursor: WireCursor&, parts: WireParts, result: silly_transport::IoResult,
    offered: i64) -> WireWrite {
    var count: i64 = 0;
    cursor.system_error = result.error;
    match result.status {
        Ready => {
            if result.count < 0 || result.count > offered {
                cursor.status = WireStatus.InvalidState;
            } else {
                count = result.count;
                advance_wire(cursor, parts, count);
                cursor.status = if wire_complete(cursor, parts) {
                    WireStatus.Complete
                } else if count == 0 {
                    WireStatus.Blocked
                } else {
                    WireStatus.Progress
                };
            }
        },
        WouldBlock => {
            cursor.status = WireStatus.Blocked;
        },
        Interrupted => {
            cursor.status = WireStatus.Interrupted;
        },
        _ => {
            cursor.status = WireStatus.Failed;
        },
    }
    return WireWrite {
        status: cursor.status,
        count: count,
        system_error: result.error
    };
}

fn wire_terminal(status: WireStatus) -> bool {
    return status == WireStatus.Complete || status == WireStatus.InvalidState || status == WireStatus.Failed;
}

fn valid_wire_cursor(cursor: WireCursor, parts: WireParts) -> bool {
    return cursor.prefix_sent >= 0 && cursor.prefix_sent <= parts.prefix.len
        && cursor.payload_sent >= 0 && cursor.payload_sent <= parts.payload.len
        && cursor.suffix_sent >= 0 && cursor.suffix_sent <= parts.suffix.len
        && (cursor.payload_sent == 0 || cursor.prefix_sent == parts.prefix.len)
        && (cursor.suffix_sent == 0 || (cursor.prefix_sent == parts.prefix.len
        && cursor.payload_sent == parts.payload.len));
}

fn wire_complete(cursor: WireCursor, parts: WireParts) -> bool {
    return cursor.prefix_sent == parts.prefix.len && cursor.payload_sent == parts.payload.len
        && cursor.suffix_sent == parts.suffix.len;
}

fn wire_offer(cursor: WireCursor, parts: WireParts, budget: i64) -> WireOffer {
    if cursor.prefix_sent < parts.prefix.len {
        let count = min(parts.prefix.len - cursor.prefix_sent, budget);
        let following = min(parts.payload.len - cursor.payload_sent, budget - count);
        return WireOffer {
            first: parts.prefix[cursor.prefix_sent..cursor.prefix_sent + count],
            second: parts.payload[cursor.payload_sent..cursor.payload_sent + following],
        };
    }
    if cursor.payload_sent < parts.payload.len {
        let count = min(parts.payload.len - cursor.payload_sent, budget);
        let following = min(parts.suffix.len - cursor.suffix_sent, budget - count);
        return WireOffer {
            first: parts.payload[cursor.payload_sent..cursor.payload_sent + count],
            second: parts.suffix[cursor.suffix_sent..cursor.suffix_sent + following],
        };
    }
    let count = min(parts.suffix.len - cursor.suffix_sent, budget);
    return WireOffer {
        first: parts.suffix[cursor.suffix_sent..cursor.suffix_sent + count],
        second: "",
    };
}

fn advance_wire(cursor: WireCursor&, parts: WireParts, count: i64) {
    var remaining = count;
    let prefix = min(remaining, parts.prefix.len - cursor.prefix_sent);
    cursor.prefix_sent += prefix;
    remaining -= prefix;
    let payload = min(remaining, parts.payload.len - cursor.payload_sent);
    cursor.payload_sent += payload;
    remaining -= payload;
    assert(remaining <= parts.suffix.len - cursor.suffix_sent);
    cursor.suffix_sent += remaining;
}
