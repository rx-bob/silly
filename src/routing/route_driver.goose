// The server borrows typed application state for its single execution owner.
namespace silly;

import.route_types;

struct RouteDriver<R, A> {
    plan: RoutePlan<R>,
    app: A&,
}
