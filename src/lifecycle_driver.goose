// Lifecycle route state remains borrowed by the single server owner.
namespace silly;

import.lifecycle_types;
import.route_types;

struct LifecycleDriver<R, A> {
    plan: RoutePlan<R>,
    app: A&,
    owner: Owner = Owner {
    },
}
