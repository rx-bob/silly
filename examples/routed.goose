// E3.S1 real server with startup registration and statically selected application routes.
namespace routed;

import silly from "..";

import std;

type Context = silly::Context<silly::NoState, silly::NoStream>;

enum Route {
    Health,
    Workspace,
    Asset,
}

fn routes(router: silly::Router<Route>&) {
    router.get("/healthz", Route.Health);
    router.scope("/api/workspaces") {
        group =>
        group.get("/:id", Route.Workspace);
    };
    router.get("/assets/*path", Route.Asset);
}

fn handle(ctx: Context&, route: Route) {
    let body = match route {
        Health => {
            "ok\n"
        },
        Workspace => {
            "workspace route\n"
        },
        Asset => {
            "asset route\n"
        },
    };
    if silly::begin_response(ctx.response, 200) != silly::ResponseError.None {
        return;
    }
    if silly::append_body(ctx.response, body) != silly::ResponseError.None {
        return;
    }
    silly::prepare_response(ctx.response);
}

fn::main() {
    let result = silly::serve<routed::Route>(silly::ServerOptions {
            port: 8081,
            ..
        }, routed::routes, routed::handle);
    if !result.ok {
        print(result.message);
        exit(1);
    }
}
