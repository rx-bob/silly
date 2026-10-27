// Handler capture views borrow compiled metadata and the original request path.
namespace silly;

import std;

import.request;
import.route_match;
import.route_types;

const EMPTY_ROUTE_SEGMENTS: RouteSegment[0] = [];

struct RouteCaptures {
    segments: const RouteSegment[:] = EMPTY_ROUTE_SEGMENTS,
    bytes: const u8[:] = "",
    path: const u8[:] = "",
}

fn route_captures<R>(plan: RoutePlan<R>, route_id: i64, target: u8[:]) -> RouteCaptures {
    if plan.issue.error != RouteError.None || route_id < 0 || route_id >= plan.entries.len {
        return RouteCaptures {
        };
    }
    let path = route_request_path(target);
    let entry = plan.entries[route_id];
    if route_request_check(path, plan.limits) != RouteMatchResult.Matched
        || entry.captures > plan.limits.captures_max || !route_entry_matches(plan, entry, path) {
        return RouteCaptures {
        };
    }
    return RouteCaptures {
        segments: plan.segments[entry.segment_start..entry.segment_start + entry.segment_count],
        bytes: plan.bytes,
        path: path,
    };
}

fn param(captures: RouteCaptures, name: u8[:]) -> FieldValue {
    var cursor: i64 = 1;
    for segment in captures.segments {
        let start = min(cursor, captures.path.len);
        let end = if segment.kind == RouteSegmentKind.CatchAll {
            captures.path.len
        } else {
            route_segment_end(captures.path, start)
        };
        if segment.kind != RouteSegmentKind.Literal
            && captures.bytes[segment.start..segment.start + segment.bytes] == name {
            return FieldValue {
                present: true,
                value: captures.path[start..end],
            };
        }
        cursor = end + 1;
    }
    return FieldValue {
    };
}

enum PathDecodeError {
    None,
    InvalidEscape,
    Limit,
}

fn path_hex(byte: u8) -> i32 {
    if byte >= '0' && byte <= '9' {
        return byte - '0';
    }
    if byte >= 'a' && byte <= 'f' {
        return (byte - 'a')as i32 + 10;
    }
    if byte >= 'A' && byte <= 'F' {
        return (byte - 'A')as i32 + 10;
    }
    return -1;
}

// Decode once into caller-owned storage. '+' stays literal; failure leaves output unchanged.
fn decode_path(out: u8[>..]&, raw: u8[:], cap: i64) -> PathDecodeError {
    if cap < 0 || out.len > cap {
        return PathDecodeError.Limit;
    }
    var cursor: i64 = 0;
    var count: i64 = 0;
    while cursor < raw.len {
        if raw[cursor] == '%' {
            if raw.len - cursor < 3 || path_hex(raw[cursor + 1]) < 0 || path_hex(raw[cursor + 2]) < 0 {
                return PathDecodeError.InvalidEscape;
            }
            cursor += 2;
        }
        count += 1;
        cursor += 1;
    }
    if count > cap - out.len {
        return PathDecodeError.Limit;
    }
    cursor = 0;
    while cursor < raw.len {
        if raw[cursor] == '%' {
            out.push((path_hex(raw[cursor + 1]) * 16 + path_hex(raw[cursor + 2]))as u8);
            cursor += 3;
        } else {
            out.push(raw[cursor]);
            cursor += 1;
        }
    }
    return PathDecodeError.None;
}
