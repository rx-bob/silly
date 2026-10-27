// Handler capture views borrow compiled metadata and the original request path.
namespace silly;

import std;

import.request;
import.route_match;
import.route_types;
import.url;

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
