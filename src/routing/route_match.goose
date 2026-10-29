// Request matching visits compiled metadata only; no declaration parsing or allocation.
namespace silly;

import.route_compile;
import.route_plan;
import.route_types;

fn route_request_path(target: u8[:]) -> const u8[:] {
    var parsed = ParsedHead {
        method: "GET",
        target: target,
        ..
    };
    if validate_target(parsed) != HeadResult.Complete {
        return "";
    }
    var start: i64 = 0;
    if parsed.target_form == TargetForm.Absolute {
        start = head_byte_index(target, ':', 0) + 3 + parsed.authority.len;
    }
    var end = target.len;
    for index in start..target.len {
        if target[index] == '?' {
            end = index;
            break;
        }
    }
    return if start == end {
        "/"
    } else {
        target[start..end]
    };
}

fn route_request_check(path: u8[:], limits: RouteLimits) -> RouteMatchResult {
    if path.len > limits.path_bytes_max {
        return RouteMatchResult.PathLimit;
    }
    if !route_path_syntax(path) {
        return RouteMatchResult.InvalidPath;
    }
    var count: i64 = 0;
    for byte in path {
        if byte == '/' {
            count += 1;
        }
    }
    if path.len == 1 {
        count = 0;
    }
    return if count > limits.segments_max {
        RouteMatchResult.SegmentLimit
    } else {
        RouteMatchResult.Matched
    };
}

fn match_route<R>(plan: RoutePlan<R>, method: u8[:], target: u8[:]) -> RouteMatch {
    if plan.issue.error != RouteError.None {
        return RouteMatch {
            result: RouteMatchResult.InvalidPlan,
            ..
        };
    }
    let path = route_request_path(target);
    var check = route_request_check(path, plan.limits);
    if method.len > plan.limits.method_bytes_max || !valid_header_name(method) {
        check = RouteMatchResult.InvalidMethod;
    }
    if check != RouteMatchResult.Matched {
        return RouteMatch {
            result: check,
            ..
        };
    }
    var result = route_select(plan, method, path);
    if result.route_id >= 0 && plan.entries[result.route_id].captures > plan.limits.captures_max {
        result.result = RouteMatchResult.CaptureLimit;
    }
    return result;
}

// Existing explicit registrations, including application fallbacks, always run first.
fn route_select<R>(plan: RoutePlan<R>, method: u8[:], path: u8[:]) -> RouteMatch {
    var selected = route_find(plan, path, method, true);
    if selected < 0 && method == "HEAD" {
        let get = route_find(plan, path, "GET", false);
        if get >= 0 && plan.entries[get].policy.head_from_get {
            selected = get;
        }
    }
    if selected >= 0 {
        return RouteMatch {
            result: RouteMatchResult.Matched,
            route_id: selected,
        };
    }
    selected = route_find(plan, path, "", false);
    var result = RouteMatch {
    };
    if selected >= 0 {
        let policy = plan.entries[selected].policy;
        if method == "OPTIONS" && policy.automatic_options {
            result.result = RouteMatchResult.GeneratedOptions;
            result.route_id = selected;
        } else if policy.method_not_allowed {
            result.result = RouteMatchResult.MethodNotAllowed;
            result.route_id = selected;
        }
    }
    return result;
}

// Empty method selects the best path across methods; no request-time pattern parsing.
fn route_find<R>(plan: RoutePlan<R>, path: u8[:], method: u8[:], accept_any: bool) -> i64 {
    var selected: i64 = -1;
    for index in plan.entries.len {
        let registered = route_method(plan, index);
        if (method.len == 0 || registered == method || (accept_any && registered.len == 0))
            && route_entry_matches(plan, plan.entries[index], path) {
            if selected < 0 || route_precedes(plan, index, selected) {
                selected = index;
            }
        }
    }
    return selected;
}

fn route_segment_end(path: u8[:], start: i64) -> i64 {
    for index in start..path.len {
        if path[index] == '/' {
            return index;
        }
    }
    return path.len;
}

fn route_entry_matches<R>(plan: RoutePlan<R>, entry: RouteEntry<R>, path: u8[:]) -> bool {
    var cursor: i64 = 1;
    for index in entry.segment_start..entry.segment_start + entry.segment_count {
        let segment = plan.segments[index];
        if segment.kind == RouteSegmentKind.CatchAll {
            return true;
        }
        if cursor > path.len {
            return false;
        }
        let end = route_segment_end(path, cursor);
        if segment.kind == RouteSegmentKind.Capture {
            if end == cursor {
                return false;
            }
        } else if plan.bytes[segment.start..segment.start + segment.bytes] != path[cursor..end] {
            return false;
        }
        cursor = end + 1;
    }
    return if entry.segment_count == 0 {
        path == "/"
    } else {
        cursor == path.len + 1
    };
}

// Literal beats capture, capture beats catch-all, exact termination beats an empty catch-all.
fn route_precedes<R>(plan: RoutePlan<R>, candidate: i64, selected: i64) -> bool {
    let a = plan.entries[candidate];
    let b = plan.entries[selected];
    let shared = if a.segment_count < b.segment_count {
        a.segment_count
    } else {
        b.segment_count
    };
    for index in shared {
        let left = route_segment_rank(plan.segments[a.segment_start + index].kind);
        let right = route_segment_rank(plan.segments[b.segment_start + index].kind);
        if left != right {
            return left > right;
        }
    }
    if a.segment_count != b.segment_count {
        return a.segment_count < b.segment_count;
    }
    return a.method_bytes > 0 && b.method_bytes == 0;
}

fn route_segment_rank(kind: RouteSegmentKind) -> i32 {
    var rank: i32 = 0;
    match kind {
        Literal => {
            rank = 2;
        },
        Capture => {
            rank = 1;
        },
        CatchAll => {
            rank = 0;
        },
    }
    return rank;
}

fn route_capture<R>(plan: RoutePlan<R>, route_id: i64, target: u8[:], name: u8[:]) -> FieldValue {
    if route_id < 0 || route_id >= plan.entries.len || plan.issue.error != RouteError.None {
        return FieldValue {
        };
    }
    let path = route_request_path(target);
    let entry = plan.entries[route_id];
    if route_request_check(path, plan.limits) != RouteMatchResult.Matched
        || entry.captures > plan.limits.captures_max
        || !route_entry_matches(plan, entry, path) {
        return FieldValue {
        };
    }
    var cursor: i64 = 1;
    var value = FieldValue {
    };
    for index in entry.segment_start..entry.segment_start + entry.segment_count {
        let segment = plan.segments[index];
        let start = if cursor > path.len {
            path.len
        } else {
            cursor
        };
        let end = if segment.kind == RouteSegmentKind.CatchAll {
            path.len
        } else {
            route_segment_end(path, start)
        };
        if segment.kind != RouteSegmentKind.Literal
            && plan.bytes[segment.start..segment.start + segment.bytes] == name {
            value = FieldValue {
                present: true,
                value: path[start..end]
            };
        }
        cursor = end + 1;
    }
    return value;
}
