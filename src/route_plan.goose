// Prepared routing exposes immutable inventory and compiled segment metadata.
namespace silly;

import.route_types;

fn prepare<R>(router: Router<R>&) -> RoutePlan<R> {
    if !valid_route_limits(router.limits) {
        route_fail(router, RouteError.InvalidLimits);
    }
    router.prepared = true;
    return RoutePlan<R> {
        entries: router.entries,
        segments: router.segments,
        bytes: router.bytes,
        limits: router.limits,
        issue: router.issue,
    };
}

fn route_path<R>(plan: RoutePlan<R>, route_id: i64) -> const u8[:] {
    assert(route_id >= 0);
    assert(route_id < plan.entries.len);
    let entry = plan.entries[route_id];
    return plan.bytes[entry.path_start..entry.path_start + entry.path_bytes];
}

fn route_method<R>(plan: RoutePlan<R>, route_id: i64) -> const u8[:] {
    assert(route_id >= 0);
    assert(route_id < plan.entries.len);
    let entry = plan.entries[route_id];
    return plan.bytes[entry.method_start..entry.method_start + entry.method_bytes];
}
