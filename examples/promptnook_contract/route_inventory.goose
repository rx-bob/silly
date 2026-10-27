// Collect startup-only route inventory for fixtures and documentation.
namespace promptnook_contract;

import std;

import.route_contract_types;
import.route_inventory_admin;
import.route_inventory_apifallback;
import.route_inventory_ideas;
import.route_inventory_nodes;
import.route_inventory_projects;
import.route_inventory_prompts;
import.route_inventory_protocol;
import.route_inventory_support;
import.route_inventory_user;
import.route_inventory_workitems;
import.route_inventory_workspaces;

fn inventory(out: RouteCase[>..]&) {
    out.append(ROUTES_SUPPORT);
    out.append(ROUTES_USER);
    out.append(ROUTES_WORKSPACES);
    out.append(ROUTES_NODES);
    out.append(ROUTES_PROMPTS);
    out.append(ROUTES_PROJECTS);
    out.append(ROUTES_WORKITEMS);
    out.append(ROUTES_IDEAS);
    out.append(ROUTES_PROTOCOL);
    out.append(ROUTES_ADMIN);
    out.append(ROUTES_APIFALLBACK);
}
