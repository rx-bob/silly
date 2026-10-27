// Inert source-derived fixture state; no business store or identity implementation.
namespace promptnook_contract;

import silly from "../..";

enum Route {
    Main,
    User,
    Workspaces,
    Export,
    Nodes,
    Prompts,
    Projects,
    WorkItems,
    Ideas,
    Flagged,
    McpSettings,
    McpProtocol,
    Admin,
    AdminHealth,
    PortalProxy,
    PortalStatic,
    ApiFallback,
    GlobalFallback,
}
struct App {
    handled: i64 = 0,
    guarded: i64 = 0,
    authorized: bool = true,
    database_ready: bool = true,
    native_owner: bool = false,
    native_started: bool = false,
    last_route: Route = Route.Main,
    id: u8[..256] = [],
    email: u8[..256] = [],
    nested_id: u8[..256] = [],
    query_value: u8[..256] = [],
    query_present: bool = false,
}
type Context = silly::Context<App, silly::NoStream>;
struct RouteCase {
    method: const u8[:],
    path: const u8[:],
    target: const u8[:],
    requirement: const u8[:],
    source: const u8[:],
    listener: const u8[:],
    route: Route,
}
struct Reply {
    family: const u8[:],
    method: const u8[:],
    target: const u8[:],
}
fn family_name(route: Route) -> const u8[:] {
    return match route {
        Main => "Main",
        User => "User",
        Workspaces => "Workspaces",
        Export => "Export",
        Nodes => "Nodes",
        Prompts => "Prompts",
        Projects => "Projects",
        WorkItems => "WorkItems",
        Ideas => "Ideas",
        Flagged => "Flagged",
        McpSettings => "McpSettings",
        McpProtocol => "McpProtocol",
        Admin => "Admin",
        AdminHealth => "AdminHealth",
        PortalProxy => "PortalProxy",
        PortalStatic => "PortalStatic",
        ApiFallback => "ApiFallback",
        GlobalFallback => "GlobalFallback",
    };
}
