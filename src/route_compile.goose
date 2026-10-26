// Startup-only pattern compilation and declaration conflict checks.
namespace silly;

import.route_types;

fn route_path_syntax(path: u8[:]) -> bool {
    if path.len == 0 || path[0] != '/' {
        return false;
    }
    for byte in path {
        if byte <= 32 || byte >= 127 || byte == '?' || byte == '#' || byte == '\\' {
            return false;
        }
    }
    return true;
}

fn route_capture_name(name: u8[:]) -> bool {
    if name.len == 0 {
        return false;
    }
    for byte in name {
        if !(byte >= 'a' && byte <= 'z') && !(byte >= 'A' && byte <= 'Z')
            && !(byte >= '0' && byte <= '9') && byte != '_' {
            return false;
        }
    }
    return true;
}

fn compile_route_segments(segments: RouteSegment[>..]&, path: u8[:], limits: RouteLimits) -> RouteError {
    if !route_path_syntax(path) {
        return RouteError.InvalidPath;
    }
    var start: i64 = 1;
    var captures: i64 = 0;
    for end in 1..path.len + 1 {
        if end < path.len && path[end] != '/' {
            continue;
        }
        // The root has no segments. Empty segments elsewhere remain significant.
        if path.len == 1 {
            continue;
        }
        var segment = RouteSegment {
            start: start,
            bytes: end - start,
            ..
        };
        let error = compile_route_segment(segment, path, end);
        if error != RouteError.None {
            return error;
        }
        if segment.kind != RouteSegmentKind.Literal {
            captures += 1;
            for previous in segments {
                if previous.kind != RouteSegmentKind.Literal
                    && path[previous.start..previous.start + previous.bytes]
                    == path[segment.start..segment.start + segment.bytes] {
                    return RouteError.DuplicateCapture;
                }
            }
        }
        if captures > limits.captures_max {
            return RouteError.CaptureLimit;
        }
        if segments.len >= limits.segments_max {
            return RouteError.SegmentLimit;
        }
        segments.push(segment);
        start = end + 1;
    }
    return RouteError.None;
}

fn compile_route_segment(segment: RouteSegment&, path: u8[:], end: i64) -> RouteError {
    var error = RouteError.None;
    if segment.bytes > 0 && (path[segment.start] == ':' || path[segment.start] == '*') {
        if path[segment.start] == '*' {
            segment.kind = RouteSegmentKind.CatchAll;
            if end != path.len {
                error = RouteError.WildcardPlacement;
            }
        } else {
            segment.kind = RouteSegmentKind.Capture;
        }
        segment.start += 1;
        segment.bytes -= 1;
        if !route_capture_name(path[segment.start..segment.start + segment.bytes]) {
            error = RouteError.InvalidCapture;
        }
    } else {
        for byte in path[segment.start..end] {
            if byte == ':' || byte == '*' {
                error = RouteError.InvalidCapture;
            }
        }
    }
    return error;
}

fn conflicting_route<R>(router: Router<R>&, method: u8[:], path: u8[:], segments: RouteSegment[:]) {
    for index in router.entries.len {
        let entry = router.entries[index];
        if method != router.bytes[entry.method_start..entry.method_start + entry.method_bytes] {
            continue;
        }
        let previous = router.segments[entry.segment_start..entry.segment_start + entry.segment_count];
        let issue = route_pattern_conflict(router.bytes, previous, path, segments);
        if issue != RouteError.None {
            route_fail(router, issue, index);
            return;
        }
    }
}

fn route_pattern_conflict(left_bytes: u8[:], left: RouteSegment[:],
    right_bytes: u8[:], right: RouteSegment[:]) -> RouteError {
    if left.len != right.len {
        return RouteError.None;
    }
    var same_names = true;
    for index in left.len {
        let a = left[index];
        let b = right[index];
        if a.kind != b.kind {
            return RouteError.None;
        }
        let same = left_bytes[a.start..a.start + a.bytes] == right_bytes[b.start..b.start + b.bytes];
        if a.kind == RouteSegmentKind.Literal && !same {
            return RouteError.None;
        }
        same_names = same_names && same;
    }
    return if same_names {
        RouteError.DuplicateRoute
    } else {
        RouteError.AmbiguousCapture
    };
}
