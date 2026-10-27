// Fixed metadata and borrowed startup/prepared routing owners.
namespace silly;

enum BodyMode {
    Buffered,
    Streamed,
}
struct RouteOptions {
    body: BodyMode = BodyMode.Buffered,
    body_bytes_max: i64 = -1,
}
struct RoutePolicy {
    head_from_get: bool = false,
    automatic_options: bool = false,
    method_not_allowed: bool = false,
}
struct RouteLimits {
    routes_max: i64 = 1024,
    path_bytes_max: i64 = 8192,
    segments_max: i64 = 128,
    captures_max: i64 = 32,
    storage_bytes_max: i64 = 1048576,
    compiled_segments_max: i64 = 16384,
    method_bytes_max: i64 = 32,
}
enum RouteError {
    None,
    InvalidLimits,
    InvalidMethod,
    InvalidPath,
    InvalidCapture,
    WildcardPlacement,
    DuplicateCapture,
    DuplicateRoute,
    AmbiguousCapture,
    RouteLimit,
    PathLimit,
    SegmentLimit,
    CaptureLimit,
    StorageLimit,
    UnsupportedOptions,
    AlreadyPrepared,
}
struct RouteIssue {
    error: RouteError = RouteError.None,
    route_id: i64 = -1,
    conflicting_route_id: i64 = -1,
}
enum RouteSegmentKind {
    Literal,
    Capture,
    CatchAll,
}
struct RouteSegment {
    kind: RouteSegmentKind = RouteSegmentKind.Literal,
    start: i64,
    bytes: i64,
}
struct RouteEntry<R> {
    method_start: i64,
    method_bytes: i64,
    path_start: i64,
    path_bytes: i64,
    segment_start: i64,
    segment_count: i64,
    captures: i64,
    action: R,
    options: RouteOptions,
    policy: RoutePolicy = RoutePolicy {
    },
}
struct Router<R> {
    entries: RouteEntry<R>[>..]&,
    segments: RouteSegment[>..]&,
    bytes: u8[>..]&,
    limits: RouteLimits = RouteLimits {
    },
    issue: RouteIssue = RouteIssue {
    },
    prefix_start: i64 = 0,
    prefix_bytes: i64 = 0,
    prepared: bool = false,
    policy: RoutePolicy = RoutePolicy {
    },
}
struct RoutePlan<R> {
    entries: const RouteEntry<R>[:],
    segments: const RouteSegment[:],
    bytes: const u8[:],
    limits: RouteLimits,
    issue: RouteIssue,
}
enum RouteMatchResult {
    Matched,
    NotFound,
    GeneratedOptions,
    MethodNotAllowed,
    InvalidMethod,
    InvalidPath,
    PathLimit,
    SegmentLimit,
    CaptureLimit,
    InvalidPlan,
}
struct RouteMatch {
    result: RouteMatchResult = RouteMatchResult.NotFound,
    route_id: i64 = -1,
}
fn valid_route_limits(limits: RouteLimits) -> bool {
    return limits.routes_max >= 0 && limits.path_bytes_max > 0 && limits.segments_max >= 0
        && limits.captures_max >= 0 && limits.storage_bytes_max >= 0
        && limits.compiled_segments_max >= 0 && limits.method_bytes_max > 0;
}

fn route_fail<R>(router: Router<R>&, error: RouteError, conflicting: i64 = -1) {
    if router.issue.error == RouteError.None {
        router.issue = RouteIssue {
            error: error,
            route_id: router.entries.len,
            conflicting_route_id: conflicting,
        };
    }
}
