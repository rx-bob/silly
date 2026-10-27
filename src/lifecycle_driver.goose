// Lifecycle route state remains borrowed by the single server owner.
namespace silly;

import.executor_types;
import.lifecycle_types;
import.route_types;

struct LifecycleDriver<R, A> {
    plan: RoutePlan<R>,
    app: A&,
    executor: ExecutorOwner = ExecutorOwner {
    },
    owner: Owner = Owner {
    },
}
