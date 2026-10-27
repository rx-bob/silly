// Bounded deterministic Allow serialization; request matching never allocates route buffers.
namespace silly;

import std;

import.response;
import.route_match;
import.route_plan;
import.route_types;

fn route_method_before(left: u8[:], right: u8[:]) -> bool {
    let shared = min(left.len, right.len);
    for index in shared {
        if left[index] != right[index] {
            return left[index] < right[index];
        }
    }
    return left.len < right.len;
}

fn route_allow_candidate(selected: u8[:], candidate: u8[:], after: u8[:]) -> const u8[:] {
    return if candidate.len > 0 && route_method_before(after, candidate)
        && (selected.len == 0 || route_method_before(candidate, selected)) {
        candidate
    } else {
        selected
    };
}

fn route_allow_next<R>(plan: RoutePlan<R>, path: u8[:], after: u8[:]) -> const u8[:] {
    var selected: const u8[:] = plan.bytes[..0];
    for index in plan.entries.len {
        if route_entry_matches(plan, plan.entries[index], path) {
            selected = route_allow_candidate(selected, route_method(plan, index), after);
        }
    }
    let get = route_find(plan, path, "GET", false);
    if get >= 0 && plan.entries[get].policy.head_from_get {
        selected = route_allow_candidate(selected, "HEAD", after);
    }
    let best = route_find(plan, path, "", false);
    if best >= 0 && plan.entries[best].policy.automatic_options {
        selected = route_allow_candidate(selected, "OPTIONS", after);
    }
    return selected;
}

fn route_allow_size<R>(plan: RoutePlan<R>, path: u8[:], cap: i64) -> i64 {
    var previous: const u8[:] = plan.bytes[..0];
    var count: i64 = 0;
    // At most one explicit method per entry plus two inferred methods.
    for step in plan.entries.len + 2 {
        let method = route_allow_next(plan, path, previous);
        if method.len == 0 {
            break;
        }
        let separator: i64 = if count == 0 {
            0
        } else {
            2
        };
        if separator > cap - count || method.len > cap - count - separator {
            return -1;
        }
        count += separator + method.len;
        previous = method;
    }
    return count;
}

// Empty any-method registrations have no finite token and are omitted from this inventory.
// cap bounds the complete destination; all validation precedes the first appended byte.
fn route_allow<R>(out: u8[>..]&, plan: RoutePlan<R>, target: u8[:], cap: i64) -> ResponseError {
    let path = route_request_path(target);
    if plan.issue.error != RouteError.None || cap < 0
        || route_request_check(path, plan.limits) != RouteMatchResult.Matched {
        return ResponseError.InvalidState;
    }
    if out.len > cap || route_allow_size(plan, path, cap - out.len) < 0 {
        return ResponseError.HeaderBytesLimit;
    }
    var previous: const u8[:] = plan.bytes[..0];
    for step in plan.entries.len + 2 {
        let method = route_allow_next(plan, path, previous);
        if method.len == 0 {
            break;
        }
        if previous.len != 0 {
            out.append(", ");
        }
        out.append(method);
        previous = method;
    }
    return ResponseError.None;
}
