// Startup registration copies declaration bytes into bounded driver-owned storage.
namespace silly;

import std;

import.execution_types;
import.headers;
import.route_compile;
import.route_types;

fn add<R>(router: Router<R>&, method: u8[:], path: u8[:], action: R, options: RouteOptions) {
    if !route_registration_ready(router, method, path, options) {
        return;
    }
    var joined: u8[>..] = [];
    joined.append(router.bytes[router.prefix_start..router.prefix_start + router.prefix_bytes]);
    joined.append(path);
    if joined.len == 0 {
        joined.append("/");
    }
    var segments: RouteSegment[>..] = [];
    let error = compile_route_segments(segments, joined, router.limits);
    if error != RouteError.None {
        route_fail(router, error);
        return;
    }
    conflicting_route(router, method, joined, segments);
    if router.issue.error == RouteError.None {
        var resolved = options;
        resolved.execution = inherited_execution(router.current_execution, options.execution);
        retain_route(router, method, joined, action, resolved, segments);
    }
}

fn add<R>(router: Router<R>&, method: u8[:], path: u8[:], action: R) {
    add(router, method, path, action, RouteOptions {
        });
}

fn route_registration_ready<R>(router: Router<R>&, method: u8[:], path: u8[:], options: RouteOptions) -> bool {
    if router.issue.error != RouteError.None {
        return false;
    }
    if router.prepared {
        route_fail(router, RouteError.AlreadyPrepared);
    } else if !valid_route_limits(router.limits) {
        route_fail(router, RouteError.InvalidLimits);
    } else if method.len > router.limits.method_bytes_max || (method.len != 0 && !valid_header_name(method)) {
        route_fail(router, RouteError.InvalidMethod);
    } else if options.body != BodyMode.Buffered || options.body_bytes_max < - 1
        || !valid_execution_class(inherited_execution(router.current_execution, options.execution))
        || inherited_execution(router.current_execution, options.execution) == ExecutionClass.Inherit {
        route_fail(router, RouteError.UnsupportedOptions);
    } else if router.entries.len >= router.limits.routes_max {
        route_fail(router, RouteError.RouteLimit);
    } else if router.prefix_bytes > router.limits.path_bytes_max
        || path.len > router.limits.path_bytes_max - router.prefix_bytes {
        route_fail(router, RouteError.PathLimit);
    } else if path.len != 0 && path[0] != '/' {
        route_fail(router, RouteError.InvalidPath);
    }
    return router.issue.error == RouteError.None;
}

fn retain_route<R>(router: Router<R>&, method: u8[:], path: u8[:], action: R,
    options: RouteOptions, segments: RouteSegment[:]) {
    if router.bytes.len > router.limits.storage_bytes_max
        || method.len > router.limits.storage_bytes_max - router.bytes.len
        || path.len > router.limits.storage_bytes_max - router.bytes.len - method.len {
        route_fail(router, RouteError.StorageLimit);
        return;
    }
    if router.segments.len > router.limits.compiled_segments_max
        || segments.len > router.limits.compiled_segments_max - router.segments.len {
        route_fail(router, RouteError.SegmentLimit);
        return;
    }
    let method_start = router.bytes.len;
    router.bytes.append(method);
    let path_start = router.bytes.len;
    router.bytes.append(path);
    let segment_start = router.segments.len;
    var captures: i64 = 0;
    for segment in segments {
        if segment.kind != RouteSegmentKind.Literal {
            captures += 1;
        }
        router.segments.push(RouteSegment {
                kind: segment.kind,
                start: path_start + segment.start,
                bytes: segment.bytes,
            });
    }
    router.entries.push(RouteEntry<R> {
            method_start: method_start,
            method_bytes: method.len,
            path_start: path_start,
            path_bytes: path.len,
            segment_start: segment_start,
            segment_count: segments.len,
            captures: captures,
            action: action,
            options: options,
            policy: router.policy,
            response_policy: router.current_response_policy,
        });
}

// Scope callbacks execute immediately; retained declarations copy the joined prefix.
fn scope<R, F>(router: Router<R>&, prefix: u8[:]) {
    if !route_registration_ready(router, "", prefix, RouteOptions {
        }) {
        return;
    }
    var joined: u8[>..] = [];
    joined.append(router.bytes[router.prefix_start..router.prefix_start + router.prefix_bytes]);
    joined.append(prefix);
    var segments: RouteSegment[>..] = [];
    let error = compile_route_segments(segments, joined, router.limits);
    if error != RouteError.None {
        route_fail(router, error);
        return;
    }
    for segment in segments {
        if segment.kind == RouteSegmentKind.CatchAll {
            route_fail(router, RouteError.WildcardPlacement);
        }
    }
    if router.bytes.len > router.limits.storage_bytes_max
        || joined.len > router.limits.storage_bytes_max - router.bytes.len {
        route_fail(router, RouteError.StorageLimit);
    }
    if router.issue.error == RouteError.None {
        let previous_start = router.prefix_start;
        let previous_bytes = router.prefix_bytes;
        let previous_policy = router.policy;
        let previous_response_policy = router.current_response_policy;
        let previous_execution = router.current_execution;
        router.prefix_start = router.bytes.len;
        router.prefix_bytes = joined.len;
        router.bytes.append(joined);
        F(router);
        router.prefix_start = previous_start;
        router.prefix_bytes = previous_bytes;
        router.policy = previous_policy;
        router.current_response_policy = previous_response_policy;
        router.current_execution = previous_execution;
    }
}

fn get<R>(router: Router<R>&, path: u8[:], action: R, options: RouteOptions) {
    add(router, "GET", path, action, options);
}

fn get<R>(router: Router<R>&, path: u8[:], action: R) {
    add(router, "GET", path, action, RouteOptions {
        });
}

fn post<R>(router: Router<R>&, path: u8[:], action: R, options: RouteOptions) {
    add(router, "POST", path, action, options);
}

fn post<R>(router: Router<R>&, path: u8[:], action: R) {
    add(router, "POST", path, action, RouteOptions {
        });
}

fn put<R>(router: Router<R>&, path: u8[:], action: R, options: RouteOptions) {
    add(router, "PUT", path, action, options);
}

fn put<R>(router: Router<R>&, path: u8[:], action: R) {
    add(router, "PUT", path, action, RouteOptions {
        });
}

fn patch<R>(router: Router<R>&, path: u8[:], action: R, options: RouteOptions) {
    add(router, "PATCH", path, action, options);
}

fn patch<R>(router: Router<R>&, path: u8[:], action: R) {
    add(router, "PATCH", path, action, RouteOptions {
        });
}

fn delete<R>(router: Router<R>&, path: u8[:], action: R, options: RouteOptions) {
    add(router, "DELETE", path, action, options);
}

fn delete<R>(router: Router<R>&, path: u8[:], action: R) {
    add(router, "DELETE", path, action, RouteOptions {
        });
}

fn head<R>(router: Router<R>&, path: u8[:], action: R, options: RouteOptions) {
    add(router, "HEAD", path, action, options);
}

fn head<R>(router: Router<R>&, path: u8[:], action: R) {
    add(router, "HEAD", path, action, RouteOptions {
        });
}

fn options<R>(router: Router<R>&, path: u8[:], action: R, options: RouteOptions) {
    add(router, "OPTIONS", path, action, options);
}

fn options<R>(router: Router<R>&, path: u8[:], action: R) {
    add(router, "OPTIONS", path, action, RouteOptions {
        });
}

fn any<R>(router: Router<R>&, path: u8[:], action: R, options: RouteOptions) {
    add(router, "", path, action, options);
}

fn any<R>(router: Router<R>&, path: u8[:], action: R) {
    add(router, "", path, action, RouteOptions {
        });
}

// Scope-local defaults are captured by each registration; explicit Inline remains an override.
fn execution<R>(router: Router<R>&, policy: ExecutionClass) {
    if router.prepared {
        route_fail(router, RouteError.AlreadyPrepared);
    } else if !valid_execution_class(policy) || policy == ExecutionClass.Inherit {
        route_fail(router, RouteError.UnsupportedOptions);
    } else {
        router.current_execution = policy;
    }
}
