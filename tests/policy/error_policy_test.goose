// Scoped snapshots distinguish existing routes, unknown families and global paths.
namespace error_policy_test;

import response_policy from "../../src/policy";
import silly from "../../";

import std;

import.route_test_fixture;

type Action = route_test::Action;

fn define(router: silly::Router<Action>&) {
    silly::get(router, "/old", route_test::Action.Root);
    silly::error_policy(router, 11);
    silly::cors(router, silly::CorsPolicy {
            origin: "*",
            methods: "GET, POST, PUT, PATCH, DELETE, OPTIONS",
            headers: "Content-Type, Authorization",
            preflight_status: 200,
            options_without_origin: true,
            ..
        });
    silly::scope(router, "/api") {
        api =>
        silly::error_policy(api, 20);
        api.policy = silly::RoutePolicy {
            head_from_get: true,
            automatic_options: true,
            method_not_allowed: true,
        };
        silly::get(api, "/a", route_test::Action.Static);
        silly::error_policy(api, 30);
        silly::get(api, "/b", route_test::Action.Update);
        silly::scope(api, "/admin") {
            admin =>
            silly::error_policy(admin, 40);
            silly::get(admin, "/known", route_test::Action.Fallback);
        };
        silly::scope(api, "/:tenant") {
            tenant => silly::get(tenant, "/read", route_test::Action.Captured)
        };
    };
    silly::scope(router, "/portal") {
        portal =>
        silly::error_policy(portal, 50);
        silly::cors(portal, silly::CorsPolicy {
            });
        silly::get(portal, "/known", route_test::Action.Root);
    };
    silly::get(router, "/outside", route_test::Action.Root);
}

fn tag(plan: silly::RoutePlan<Action>, target: u8[:], expected: i64) {
    const fields: silly::HeaderView[0] = [];
    let result = silly::response_policy(plan, "GET", target, fields);
    assert(result.error == silly::ResponseError.None);
    assert(result.error_policy == expected);
}

fn verify(plan: silly::RoutePlan<Action>) {
    assert(plan.issue.error == silly::RouteError.None);
    assert(plan.response_policies.len == 7);
    tag(plan, "/old", 0);
    tag(plan, "/missing", 11);
    tag(plan, "/outside", 11);
    tag(plan, "/portal/missing", 50);
    tag(plan, "/api/a", 20);
    tag(plan, "/api/b", 30);
    tag(plan, "/api/missing", 30);
    tag(plan, "/api", 30);
    tag(plan, "/api/admin/known", 40);
    tag(plan, "/api/admin/missing", 40);
    tag(plan, "/api/tenant/read", 30);
    tag(plan, "/apiary/missing", 11);
    tag(plan, "/api%2fadmin/missing", 11);
    tag(plan, "/outside?next=/api/admin", 11);
    tag(plan, "https://example.test/api/admin/missing?x=1", 40);
    const fields: silly::HeaderView[0] = [];
    let method = silly::response_policy(plan, "POST", "/api/a", fields);
    assert(method.method_not_allowed);
    assert(method.error_policy == 20);
    assert(method.allow == "GET, HEAD, OPTIONS");
    let options = silly::response_policy(plan, "OPTIONS", "/api/missing", fields);
    assert(options.cors.early_status == 200);
    let old = silly::response_policy(plan, "GET", "/old", fields);
    assert(!old.cors.enabled);
    let portal = silly::response_policy(plan, "GET", "/portal/known", fields);
    assert(portal.error_policy == 50);
    assert(!portal.cors.enabled);
    let portal_miss = silly::response_policy(plan, "GET", "/portal/missing", fields);
    assert(!portal_miss.cors.enabled);
}

fn no_policy(router: silly::Router<Action>&) {
    router.policy.method_not_allowed = true;
    silly::get(router, "/", route_test::Action.Root);
}

fn no_policy_check(plan: silly::RoutePlan<Action>) {
    const fields: silly::HeaderView[0] = [];
    let result = silly::response_policy(plan, "POST", "/", fields);
    assert(result.error == silly::ResponseError.None);
    assert(!result.method_not_allowed);
    assert(result.allow.len == 0);
}

fn captured_config(router: silly::Router<Action>&) {
    silly::scope(router, "/:tenant") {
        scoped => silly::error_policy(scoped, 1)
    };
}

fn invalid(plan: silly::RoutePlan<Action>) {
    assert(plan.issue.error == silly::RouteError.InvalidPolicy);
}

fn negative_tag(router: silly::Router<Action>&) {
    silly::error_policy(router, -1);
}

fn invalid_cors(router: silly::Router<Action>&) {
    silly::cors(router, silly::CorsPolicy {
            origin: "*",
            credentials: true,
            ..
        });
}

fn policy_limit(router: silly::Router<Action>&) {
    silly::error_policy(router, 1);
    silly::error_policy(router, 2);
    silly::error_policy(router, 3);
}

fn limited(plan: silly::RoutePlan<Action>) {
    assert(plan.issue.error == silly::RouteError.PolicyLimit);
    assert(plan.response_policies.len == 2);
}

fn ephemeral_config(router: silly::Router<Action>&) {
    var origin: u8[>..] = "https://one.test";
    silly::cors(router, silly::CorsPolicy {
            origin: origin,
            ..
        });
    origin.clear();
    origin.append("https://evil.test");
    silly::get(router, "/", route_test::Action.Root);
}

fn retained(plan: silly::RoutePlan<Action>) {
    assert(plan.issue.error == silly::RouteError.None);
    assert(plan.response_policies[0].cors.origins == "https://one.test");
    let fields = [silly::HeaderView {
            name: "Origin",
            value: "https://one.test"
        }];
    let result = silly::response_policy(plan, "GET", "/", fields);
    assert(result.cors.allowed);
    assert(result.cors.origin == "https://one.test");
}

fn prepared() {
    var entries: silly::RouteEntry<Action>[>..] = [];
    var segments: silly::RouteSegment[>..] = [];
    var bytes: u8[>..] = [];
    var router = silly::Router<Action> {
        entries: entries,
        segments: segments,
        bytes: bytes,
        ..
    };
    silly::error_policy(router, 1);
    assert(silly::prepare(router).issue.error == silly::RouteError.None);
    silly::error_policy(router, 2);
    assert(router.issue.error == silly::RouteError.AlreadyPrepared);
    assert(router.response_policies.len == 1);
}

fn::main() {
    route_test::with_plan(silly::RouteLimits {
        }, error_policy_test::define, error_policy_test::verify);
    route_test::with_plan(silly::RouteLimits {
        }, error_policy_test::no_policy, error_policy_test::no_policy_check);
    route_test::with_plan(silly::RouteLimits {
        }, error_policy_test::captured_config, error_policy_test::invalid);
    route_test::with_plan(silly::RouteLimits {
        }, error_policy_test::negative_tag, error_policy_test::invalid);
    route_test::with_plan(silly::RouteLimits {
        }, error_policy_test::invalid_cors, error_policy_test::invalid);
    route_test::with_plan(silly::RouteLimits {
            response_policies_max: 2,
            ..
        },
        error_policy_test::policy_limit, error_policy_test::limited);
    route_test::with_plan(silly::RouteLimits {
        }, error_policy_test::ephemeral_config, error_policy_test::retained);
    error_policy_test::prepared();
    print("scoped immutable response policies passed");
}
