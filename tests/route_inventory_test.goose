// E1.S1 method/path-shape inventory: domain handlers remain application-owned.
namespace route_inventory_test;

import silly from "..";

import std;

struct Shape {
    requirement: const u8[:],
    method: const u8[:],
    pattern: const u8[:],
    request: const u8[:],
}

fn verify(shapes: Shape[:]) {
    var entries: silly::RouteEntry<i64>[>..] = [];
    var segments: silly::RouteSegment[>..] = [];
    var bytes: u8[>..] = [];
    var router = silly::Router<i64> {
        entries: entries,
        segments: segments,
        bytes: bytes,
        ..
    };
    for index in shapes.len {
        let shape = shapes[index];
        silly::add(router, shape.method, shape.pattern, index);
    }
    let plan = silly::prepare(router);
    assert(plan.issue.error == silly::RouteError.None);
    assert(plan.entries.len == shapes.len);
    for index in shapes.len {
        let shape = shapes[index];
        assert(shape.requirement.len > 0);
        assert(silly::route_path(plan, index) == shape.pattern);
        assert(silly::route_method(plan, index) == shape.method);
        assert(plan.entries[index].action == index);
        let method = if shape.method == "" {
            "TRACE"
        } else {
            shape.method
        };
        let matched = silly::match_route(plan, method, shape.request);
        assert(matched.result == silly::RouteMatchResult.Matched);
        assert(matched.route_id == index);
    }
}

fn shape(requirement: u8[:], method: u8[:], pattern: u8[:], request: u8[:]) -> Shape {
    return Shape {
        requirement: requirement,
        method: method,
        pattern: pattern,
        request: request
    };
}

fn domains() {
    let shapes = [
        shape("R02", "GET", "/", "/"),
        shape("R02", "GET", "/healthz", "/healthz"),
        shape("R02", "GET", "/db/health", "/db/health"),
        shape("R02", "OPTIONS", "/api/workspaces", "/api/workspaces"),
        shape("R02", "POST", "/api/test/reset-db", "/api/test/reset-db"),
        shape("R03", "GET", "/api/user/auth-config", "/api/user/auth-config"),
        shape("R03", "POST", "/api/user/signup", "/api/user/signup"),
        shape("R03", "POST", "/api/user/login", "/api/user/login"),
        shape("R03", "GET", "/api/user/me", "/api/user/me"),
        shape("R03", "PATCH", "/api/user/me", "/api/user/me"),
        shape("R03", "GET", "/api/user/preferences", "/api/user/preferences"),
        shape("R03", "PUT", "/api/user/preferences", "/api/user/preferences"),
        shape("R03", "GET", "/api/user/sso/callback", "/api/user/sso/callback"),
        shape("R04", "GET", "/api/workspaces", "/api/workspaces"),
        shape("R04", "POST", "/api/workspaces", "/api/workspaces"),
        shape("R04", "PATCH", "/api/workspaces/:id", "/api/workspaces/w1"),
        shape("R04", "PUT", "/api/workspaces/:id", "/api/workspaces/w1"),
        shape("R04", "DELETE", "/api/workspaces/:id", "/api/workspaces/w1"),
        shape("R04", "GET", "/api/workspaces/:id/share", "/api/workspaces/w1/share"),
        shape("R04", "GET", "/api/workspaces/:id/tree", "/api/workspaces/w1/tree"),
        shape("R05", "GET", "/api/workspaces/:id/export", "/api/workspaces/w1/export"),
        shape("R04", "POST", "/api/workspaces/:id/collaborators", "/api/workspaces/w1/collaborators"),
        shape("R04", "PATCH", "/api/workspaces/:id/collaborators/:email", "/api/workspaces/w1/collaborators/a@b.test"),
        shape("R04", "DELETE", "/api/workspaces/:id/collaborators/:email", "/api/workspaces/w1/collaborators/a%2Bb"),
    ];
    verify(shapes);
}

fn nested_domains() {
    let shapes = [
        shape("R06", "POST", "/api/nodes", "/api/nodes"),
        shape("R06", "PATCH", "/api/nodes/:id", "/api/nodes/n1"),
        shape("R06", "GET", "/api/nodes/:id/variables", "/api/nodes/n1/variables"),
        shape("R06", "PUT", "/api/nodes/:id/variables", "/api/nodes/n1/variables"),
        shape("R06", "POST", "/api/nodes/:id/value-sets/:set/duplicate", "/api/nodes/n1/value-sets/v1/duplicate"),
        shape("R07", "GET", "/api/prompts/:id", "/api/prompts/p1"),
        shape("R07", "PATCH", "/api/prompts/:id/storage", "/api/prompts/p1/storage"),
        shape("R07", "PUT", "/api/prompts/:id/storage", "/api/prompts/p1/storage"),
        shape("R07", "GET", "/api/prompts/:id/versions/:version", "/api/prompts/p1/versions/123"),
        shape("R07", "POST", "/api/prompts/:id/versions/:version/restore", "/api/prompts/p1/versions/123/restore"),
        shape("R08", "GET", "/api/projects", "/api/projects"),
        shape("R08", "POST", "/api/projects/:id/initiatives", "/api/projects/p1/initiatives"),
        shape("R08", "GET", "/api/initiatives/:id/epics", "/api/initiatives/i1/epics"),
        shape("R08", "POST", "/api/epics/:id/stories", "/api/epics/e1/stories"),
        shape("R08", "PATCH", "/api/stories/:id/status", "/api/stories/s1/status"),
        shape("R08", "DELETE", "/api/stories/:id/links/:link", "/api/stories/s1/links/l1"),
        shape("R08", "GET", "/api/stories/:id/activity", "/api/stories/s1/activity"),
        shape("R09", "GET", "/api/ideas", "/api/ideas"),
        shape("R09", "PATCH", "/api/ideas/:id", "/api/ideas/i1"),
        shape("R09", "POST", "/api/ideas/:id/unarchive", "/api/ideas/i1/unarchive"),
        shape("R09", "POST", "/api/ideas/:id/promote", "/api/ideas/i1/promote"),
        shape("R09", "GET", "/api/projects/:id/ideas", "/api/projects/p1/ideas"),
        shape("R10", "GET", "/api/flagged/count", "/api/flagged/count"),
        shape("R10", "PUT", "/api/flagged/:id", "/api/flagged/f1"),
        shape("R10", "POST", "/api/v1/flagged/report", "/api/v1/flagged/report"),
    ];
    verify(shapes);
}

fn admin_protocol_portal() {
    let shapes = [
        shape("R11", "GET", "/api/v1/prompts/list", "/api/v1/prompts/list"),
        shape("R11", "POST", "/api/v1/prompts/run", "/api/v1/prompts/run"),
        shape("R12", "GET", "/api/mcp/token", "/api/mcp/token"),
        shape("R12", "POST", "/api/mcp/token/regenerate", "/api/mcp/token/regenerate"),
        shape("R12", "GET", "/api/mcp/usage/hourly", "/api/mcp/usage/hourly"),
        shape("R12", "GET", "/api/mcp/calls/recent", "/api/mcp/calls/recent"),
        shape("R12", "DELETE", "/api/mcp/integrations/:id", "/api/mcp/integrations/m1"),
        shape("R12", "POST", "/api/mcp/integrations/:id/test-connection", "/api/mcp/integrations/m1/test-connection"),
        shape("R13", "GET", "/api/admin-health", "/api/admin-health"),
        shape("R13", "GET", "/api/admin/meta", "/api/admin/meta"),
        shape("R13", "GET", "/api/admin/users/by-email", "/api/admin/users/by-email"),
        shape("R13", "GET", "/api/admin/workspaces/by-id", "/api/admin/workspaces/by-id"),
        shape("R13", "POST", "/api/admin/prompts/edit", "/api/admin/prompts/edit"),
        shape("R13", "GET", "/api/admin/nodes/value-sets", "/api/admin/nodes/value-sets"),
        shape("R14", "GET", "/api/admin/raw/exact", "/api/admin/raw/exact"),
        shape("R14", "POST", "/api/admin/raw/exact", "/api/admin/raw/exact"),
        shape("R14", "GET", "/api/admin/raw/prefix", "/api/admin/raw/prefix"),
        shape("R15", "", "/portal-api/*path", "/portal-api/api/workspaces/w1"),
        shape("R15", "HEAD", "/static/*path", "/static/js/app.js"),
        shape("R15", "GET", "/*path", "/assets/logo.svg"),
        shape("H01", "CUSTOM", "/extension", "/extension"),
    ];
    verify(shapes);
}

fn::main() {
    route_inventory_test::domains();
    route_inventory_test::nested_domains();
    route_inventory_test::admin_protocol_portal();
    print("consumer method/path-shape inventory passed");
}
