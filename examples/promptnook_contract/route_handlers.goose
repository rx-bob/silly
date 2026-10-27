// Deterministic response and guard probes, not application business handlers.
namespace promptnook_contract;

import silly from "../..";

import std;

import.route_contract_types;

fn global_before<C>(ctx: C&, route: Route) {
    ctx.app.guarded += 1;
}

fn group_before<C>(ctx: C&, route: Route) {
    if !ctx.app.database_ready && route != Route.Main && route != Route.User
        && route != Route.PortalStatic && route != Route.PortalProxy {
        ctx.reject_text(503, "Database unavailable");
    }
}

fn route_before<C>(ctx: C&, route: Route) {
    if !ctx.app.authorized && route != Route.Main && route != Route.User
        && route != Route.AdminHealth && route != Route.PortalStatic && route != Route.GlobalFallback {
        if route == Route.McpProtocol {
            ctx.bytes(401, "Missing token or session");
            ctx.reject();
        }
        ctx.json_bytes(401, "{\"error\":\"Unauthorized\"}");
        ctx.reject();
    }
}

fn capture_request<C>(ctx: C&) {
    let id = ctx.param("id").value;
    let email = ctx.param("email").value;
    let nested = ctx.param("nested_id").value;
    if id.len > ctx.app.id.cap || email.len > ctx.app.email.cap || nested.len > ctx.app.nested_id.cap {
        ctx.reject_text(413, "Fixture capture limit");
    }
    var scratch: u8[>..] = [];
    let query = silly::query(ctx, "key", scratch);
    if query.value.len > ctx.app.query_value.cap {
        ctx.reject_text(413, "Fixture query limit");
    }
    ctx.app.id.clear();
    ctx.app.id.append(id);
    ctx.app.email.clear();
    ctx.app.email.append(email);
    ctx.app.nested_id.clear();
    ctx.app.nested_id.append(nested);
    ctx.app.query_value.clear();
    ctx.app.query_present = query.present;
    ctx.app.query_value.append(query.value);
}

fn respond<C>(ctx: C&, route: Route) {
    capture_request(ctx);
    ctx.app.handled += 1;
    ctx.app.last_route = route;
    let fallback = route == Route.ApiFallback || route == Route.GlobalFallback
        || ((route == Route.Admin || route == Route.McpProtocol) && ctx.param("path").present);
    if fallback {
        ctx.json_bytes(404, "{\"error\":\"Not found\"}");
    } else {
        var reply = Reply {
            family: family_name(route),
            method: ctx.request.method,
            target: ctx.request.target
        };
        ctx.json(200, reply);
    }
}
