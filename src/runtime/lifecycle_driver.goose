// Lifecycle route state remains borrowed by the single server owner.
namespace silly;

import.executor_types;
import.lifecycle_types;

struct LifecycleDriver<R, A> {
    plan: RoutePlan<R>,
    app: A&,
    control_epoch: i64 = 0,
    executor: ExecutorOwner = ExecutorOwner {
    },
    owner: Owner = Owner {
    },
}
