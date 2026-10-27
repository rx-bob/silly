// Executable consumer routing contract; domain behavior and native dependencies remain in PromptNook.
namespace promptnook_contract;

import silly from "../..";

import std;

import.route_contract_types;
import.route_handlers;
import.route_inventory;

fn routes(router: silly::Router<Route>&, app: App&) {
    declare_inventory(router, "api");
}

fn portal_routes(router: silly::Router<Route>&, app: App&) {
    declare_inventory(router, "portal");
}

fn declare_inventory(router: silly::Router<Route>&, listener: u8[:]) {
    var cases: RouteCase[>..] = [];
    inventory(cases);
    for item in cases {
        if item.listener == listener {
            silly::add(router, item.method, item.path, item.route);
        }
    }
}

fn handle<C>(ctx: C&, route: Route) {
    // The source API handles OPTIONS before any database or authorization checks.
    if ctx.request.method == "OPTIONS" && route != Route.PortalProxy && route != Route.PortalStatic {
        ctx.app.handled += 1;
        ctx.app.last_route = route;
        ctx.empty(200);
    } else {
        silly::middleware(ctx, route, global_before, group_before, route_before, respond);
    }
}
