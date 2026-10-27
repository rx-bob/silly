// Lifecycle route state remains borrowed by the single server owner.
namespace silly;

import.route_types;

struct LifecycleDriver<R, A> {
    plan: RoutePlan<R>,
    app: A&,
}
