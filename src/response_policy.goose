// Immutable policy snapshots preserve known-route declarations and classify scoped misses.
namespace silly;

import.cors;
import.cors_types;
import.headers;
import.http_head_types;
import.lifecycle_driver;
import.response;
import.response_policy_types;
import.route_compile;
import.route_driver;
import.route_match;
import.route_policy;
import.route_types;
import.state;

fn response_policy_ready<R>(router: Router<R>&) -> bool {
    if router.issue.error != RouteError.None {
        return false;
    }
    if router.prepared {
        route_fail(router, RouteError.AlreadyPrepared);
    } else if !valid_route_limits(router.limits) {
        route_fail(router, RouteError.InvalidLimits);
    } else if router.response_policies.len >= router.limits.response_policies_max {
        route_fail(router, RouteError.PolicyLimit);
    } else if !literal_policy_prefix(router) {
        route_fail(router, RouteError.InvalidPolicy);
    }
    return router.issue.error == RouteError.None;
}

fn literal_policy_prefix<R>(router: Router<R>&) -> bool {
    if router.prefix_bytes == 0 {
        return true;
    }
    let prefix = router.bytes[router.prefix_start..router.prefix_start + router.prefix_bytes];
    var segments: RouteSegment[>..] = [];
    if compile_route_segments(segments, prefix, router.limits) != RouteError.None {
        return false;
    }
    for segment in segments {
        if segment.kind != RouteSegmentKind.Literal {
            return false;
        }
    }
    return true;
}

fn inherited_response_policy<R>(router: Router<R>&) -> ResponsePolicyEntry {
    var policy = ResponsePolicyEntry {
        prefix_start: router.prefix_start,
        prefix_bytes: router.prefix_bytes,
        ..
    };
    if router.current_response_policy >= 0 {
        policy.error_policy = router.response_policies[router.current_response_policy].error_policy;
        policy.cors = router.response_policies[router.current_response_policy].cors;
    }
    return policy;
}

fn cors<R>(router: Router<R>&, policy: CorsPolicy) {
    if !response_policy_ready(router) {
        return;
    }
    let compiled = compile_cors(policy);
    if compiled.error != ResponseError.None {
        route_fail(router, RouteError.InvalidPolicy);
        return;
    }
    var entry = inherited_response_policy(router);
    entry.cors = compiled;
    router.current_response_policy = router.response_policies.len;
    router.response_policies.push(entry);
}

fn error_policy<R>(router: Router<R>&, tag: i64) {
    if !response_policy_ready(router) {
        return;
    }
    if tag < 0 {
        route_fail(router, RouteError.InvalidPolicy);
        return;
    }
    var entry = inherited_response_policy(router);
    entry.error_policy = tag;
    router.current_response_policy = router.response_policies.len;
    router.response_policies.push(entry);
}

fn response_policy_prefix(prefix: u8[:], path: u8[:]) -> bool {
    if prefix.len == 0 || prefix == "/" {
        return path.len > 0 && path[0] == '/';
    }
    return path.len >= prefix.len && path[..prefix.len] == prefix
        && (path.len == prefix.len || path[prefix.len] == '/');
}

// Unknown paths choose the longest configured literal prefix; latest declaration wins ties.
fn scoped_response_policy<R>(plan: RoutePlan<R>, path: u8[:]) -> i64 {
    var selected: i64 = -1;
    var length: i64 = -1;
    for index in plan.response_policies.len {
        let entry = plan.response_policies[index];
        let prefix = plan.bytes[entry.prefix_start..entry.prefix_start + entry.prefix_bytes];
        if entry.prefix_bytes >= length && response_policy_prefix(prefix, path) {
            selected = index;
            length = entry.prefix_bytes;
        }
    }
    return selected;
}

fn response_policy<R>(plan: RoutePlan<R>, method: u8[:], target: u8[:], fields: HeaderView[:]) -> ResponsePolicyState {
    var state = ResponsePolicyState {
    };
    let selected = match_route(plan, method, target);
    if selected.result == RouteMatchResult.InvalidPlan {
        state.error = ResponseError.InvalidState;
        return state;
    }
    let path = route_request_path(target);
    if route_request_check(path, plan.limits) != RouteMatchResult.Matched {
        return state;
    }
    let index = if selected.route_id >= 0 {
        plan.entries[selected.route_id].response_policy
    } else {
        scoped_response_policy(plan, path)
    };
    if index >= 0 && index < plan.response_policies.len {
        let entry = plan.response_policies[index];
        state.error_policy = entry.error_policy;
        state.cors = decide_cors(entry.cors, method, fields);
    }
    if index >= 0 && index < plan.response_policies.len && selected.result == RouteMatchResult.MethodNotAllowed {
        state.method_not_allowed = true;
        var allow: u8[>..] = [];
        state.error = route_allow(allow, plan, target, state.allow.cap);
        if state.error == ResponseError.None {
            state.allow.append(allow);
        }
    }
    return state;
}

fn resolve_response_policy(driver: NoState&, parsed: ParsedHead, fields: HeaderView[:]) -> ResponsePolicyState {
    return ResponsePolicyState {
    };
}

fn resolve_response_policy<R>(driver: RoutePlan<R>&, parsed: ParsedHead,
    fields: HeaderView[:]) -> ResponsePolicyState {
    return response_policy(driver, parsed.method, parsed.target, fields);
}

fn resolve_response_policy<R, A>(driver: RouteDriver<R, A> & , parsed: ParsedHead,
    fields: HeaderView[:]) -> ResponsePolicyState {
    return resolve_response_policy(driver.plan, parsed, fields);
}

fn resolve_response_policy<R, A>(driver: LifecycleDriver<R, A> & , parsed: ParsedHead,
    fields: HeaderView[:]) -> ResponsePolicyState {
    return resolve_response_policy(driver.plan, parsed, fields);
}
