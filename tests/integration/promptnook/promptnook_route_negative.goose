// Scope boundaries, exact arity, query identity and terminal guards remain observable.
namespace promptnook_route_test;

import routes from "../../../examples/promptnook_contract";
import silly from "../../../";

import std;

import.promptnook_route_fixture;

type Route = promptnook_contract::Route;
fn api_negatives(plan: silly::RoutePlan<Route>&) {
    var app = promptnook_contract::App {
    };
    exercise(plan, "GET", "/api/workspaces/raw%2Fid/share/extra", promptnook_contract::Route.ApiFallback, 404, app);
    exercise(plan, "PUT", "/api/projects/raw%2Fid", promptnook_contract::Route.ApiFallback, 404, app);
    exercise(plan, "GET", "/api/stories/raw%2Fid/activity", promptnook_contract::Route.ApiFallback, 404, app);
    exercise(plan, "POST", "/api/ideas/raw%2Fid/promote", promptnook_contract::Route.ApiFallback, 404, app);
    exercise(plan, "GET", "/api/user/auth-config", promptnook_contract::Route.ApiFallback, 404, app);
    exercise(plan, "POST", "/api/mcp/integrations/raw%2Fid/test-connection",
        promptnook_contract::Route.ApiFallback, 404, app);
    exercise(plan, "GET", "/api/adminish/meta", promptnook_contract::Route.GlobalFallback, 404, app);
    exercise(plan, "GET", "/api/admin/users/by-id/extra?user_id=x", promptnook_contract::Route.Admin, 404, app);
    exercise(plan, "GET", "/api/admin/raw/exact?key=raw%2Fkey&empty=", promptnook_contract::Route.Admin, 200, app);
    assert(app.query_present);
    assert(app.query_value == "raw/key");
    exercise(plan, "GET", "/api/admin/raw/exact?key=", promptnook_contract::Route.Admin, 200, app);
    assert(app.query_present);
    assert(app.query_value.len == 0);
    exercise(plan, "GET", "/api/admin/raw/exact", promptnook_contract::Route.Admin, 200, app);
    assert(!app.query_present);
    exercise(plan, "PATCH", "/api/workspaces/raw%2Fid/collaborators/a%2Bb@example.test",
        promptnook_contract::Route.Workspaces, 200, app);
    assert(app.id == "raw%2Fid");
    assert(app.email == "a%2Bb@example.test");
    exercise(plan, "GET", "/api/admin/users/by-id?user_id=x", promptnook_contract::Route.Admin, 200, app);
    assert(app.id.len == 0);
    exercise(plan, "GET", "/api/v1/prompts/detail?id=x", promptnook_contract::Route.McpProtocol, 200, app);
    assert(app.id.len == 0);
    guard_negatives(plan);
    oversize(plan);
}

fn guard_negatives(plan: silly::RoutePlan<Route>&) {
    var app = promptnook_contract::App {
        authorized: false,
        ..
    };
    exercise(plan, "GET", "/api/admin/users/by-id?user_id=x", promptnook_contract::Route.Admin, 401, app);
    exercise(plan, "GET", "/api/v1/prompts/detail?id=x", promptnook_contract::Route.McpProtocol, 401, app);
    exercise(plan, "GET", "/api/workspaces", promptnook_contract::Route.Workspaces, 401, app);
    assert(app.handled == 0);
    assert(app.guarded == 3);
    exercise(plan, "GET", "/api/admin/unknown", promptnook_contract::Route.Admin, 401, app);
    exercise(plan, "GET", "/api/v1/unknown", promptnook_contract::Route.McpProtocol, 401, app);
    assert(app.handled == 0);
    exercise(plan, "GET", "/api/admin-health", promptnook_contract::Route.AdminHealth, 200, app);
    assert(app.handled == 1);
    app.database_ready = false;
    exercise(plan, "GET", "/api/nodes/x/variables", promptnook_contract::Route.Nodes, 503, app);
    assert(app.handled == 1);
    exercise(plan, "OPTIONS", "/api/workspaces", promptnook_contract::Route.ApiFallback, 200, app);
    assert(app.handled == 2);
}

fn portal_negatives(plan: silly::RoutePlan<Route>&) {
    var app = promptnook_contract::App {
    };
    exercise(plan, "GET", "/portal-apiary/app.js", promptnook_contract::Route.PortalStatic, 200, app);
    exercise(plan, "GET", "/", promptnook_contract::Route.PortalStatic, 200, app);
    exercise(plan, "GET", "/portal-api", promptnook_contract::Route.PortalProxy, 200, app);
    exercise(plan, "POST", "/portal-api/api/workspaces?env=test", promptnook_contract::Route.PortalProxy, 200, app);
    let rejected = silly::match_route(plan, "POST", "/index.html");
    assert(rejected.result == silly::RouteMatchResult.NotFound);
}

fn oversize(plan: silly::RoutePlan<Route>&) {
    var app = promptnook_contract::App {
    };
    let long: u8[257] = ['x'; 257];
    let target = str("/api/workspaces/", long, "/tree");
    exercise(plan, "GET", target, promptnook_contract::Route.Workspaces, 413, app);
    let query = str("/api/admin/raw/exact?key=", long);
    exercise(plan, "GET", query, promptnook_contract::Route.Admin, 413, app);
    assert(app.handled == 0);
}
