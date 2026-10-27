// Static policy registration methods preserve scoped public syntax.

import.cors_types;
import.response_policy;
import.route_types;

fn cors<R>(router: silly::Router<R>&, policy: silly::CorsPolicy) {
    silly::cors(router, policy);
}

fn error_policy<R>(router: silly::Router<R>&, tag: i64) {
    silly::error_policy(router, tag);
}
