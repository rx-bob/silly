// Executable minimal application with typed JSON input and output.
// Registration, method policy, endpoint guards and JSON are implemented through E4.S3.
namespace basic_app;

import silly from "..";

import std;

type Context = silly::Context<silly::NoState, silly::NoStream>;

enum Route {
    Health,
    CreateWorkspace,
}

struct WorkspaceInput {
    name: const u8[:],
}

struct WorkspaceReply {
    name: const u8[:],
}

// Runs once during preparation, before the listener accepts requests.
fn routes(router: silly::Router<Route>&) {
    router.get("/healthz", Route.Health);
    router.scope("/api/workspaces") {
        group =>
        group.policy = silly::RoutePolicy {
            head_from_get: true,
            automatic_options: true,
            method_not_allowed: true,
        };
        group.post("", Route.CreateWorkspace);
    };
}

// Runs only after the prepared router has selected one route value.
fn handle(ctx: Context&, route: Route) {
    match route {
        Health => {
            ctx.respond_text(200, "ok");
        },
        CreateWorkspace => {
            create_workspace(ctx);
        },
    }
}

fn create_workspace(ctx: Context&) {
    var scratch: u8[>..] = [];
    let input = silly::require_json<WorkspaceInput>(ctx, scratch);
    let reply = WorkspaceReply {
        name: input.name,
    };
    ctx.json(201, reply);
}

fn::main() {
    let options = silly::ServerOptions {
        address: "127.0.0.1",
        port: 8081,
        limits: silly::Limits {
            body_bytes_max: 8 * 1024 * 1024,
            ..
        },
        ..
    };
    let result = silly::serve<basic_app::Route>(options, basic_app::routes, basic_app::handle);
    if !result.ok {
        print(result.message);
        exit(1);
    }
}
