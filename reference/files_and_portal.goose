// Executable Portal static listener. Create ./public, build, then request localhost:8082/.
// /portal-api selects an inert axiom environment at port 8083, with source-derived query/auth policy.
namespace portal_reference;

import client from "../client";
import portal_proxy from "../examples/promptnook_contract";
import proxy from "../client";
import silly from "..";

import std;

struct AppState {
    executor: silly::FileExecutor,
    root: silly::FileRoot,
    client: silly_client::Client,
}
struct Transfer {
    proxy: bool = false,
    file: silly::StaticTransfer = silly::StaticTransfer {
    },
    upstream: silly_client::ProxyTransfer = silly_client::ProxyTransfer {
    },
}
type Context = silly::Context<AppState, Transfer>;
enum Route {
    Static,
    Proxy
}

fn routes(router: silly::Router<Route>&, app: AppState&) {
    router.any("/portal-api", Route.Proxy, silly::RouteOptions {
            body: silly::BodyMode.Streamed,
            ..
        });
    router.any("/portal-api/*path", Route.Proxy, silly::RouteOptions {
            body: silly::BodyMode.Streamed,
            ..
        });
    router.any("/*path", Route.Static);
}

fn handle(ctx: Context&, route: Route) {
    let result = if route == Route.Proxy {
        proxy_response(ctx)
    } else {
        static_response(ctx)
    };
    if result != silly::ResponseError.None {
        silly::fail_response(ctx.response, result);
    }
}

fn static_response(ctx: Context&) -> silly::ResponseError {
    let sink = ctx.stream_start;
    guard sink else {
        return silly::ResponseError.InvalidState;
    }
    var pending = silly::StreamStart<silly::StaticTransfer> {
    };
    var leaf = silly::Context<AppState, silly::StaticTransfer> {
        request: ctx.request,
        response: ctx.response,
        app: ctx.app,
        stream_start: pending,
        audit: ctx.audit,
        route_captures: ctx.route_captures,
    };
    let result = silly::static_mount_response(leaf, silly::FileMount {
            executor: ctx.app.executor,
            root: ctx.app.root,
            directory_policy: silly::DirectoryPolicy.List,
            missing_policy: silly::MissingFilePolicy.RootListing,
            gzip_freshness_ms: 10,
            ..
        });
    if pending.selected {
        sink.state.file = pending.state;
        sink.selected = true;
        sink.defer_headers = pending.defer_headers;
        sink.pending_bytes_max = pending.pending_bytes_max;
    }
    return result;
}

fn proxy_response(ctx: Context&) -> silly::ResponseError {
    let sink = ctx.stream_start;
    guard sink else {
        return silly::ResponseError.InvalidState;
    }
    var pending = silly::StreamStart<silly_client::ProxyTransfer> {
    };
    var leaf = silly::Context<AppState, silly_client::ProxyTransfer> {
        request: ctx.request,
        response: ctx.response,
        app: ctx.app,
        stream_start: pending,
        audit: ctx.audit,
        route_captures: ctx.route_captures,
    };
    const environments = [promptnook_portal::Environment {
            name: "axiom",
            base_url: "http://127.0.0.1:8083/api/admin",
            token_configured: false,
            ..
        }];
    var prepared = promptnook_portal::prepare(ctx.request, promptnook_portal::Config {
            environments: environments,
            ..
        });
    if prepared.error != promptnook_portal::PortalError.None {
        let failure = promptnook_portal::policy_response(prepared);
        return silly::respond_bytes(ctx, failure.status, failure.body);
    }
    let result = promptnook_portal::start(leaf, ctx.app.client, prepared);
    if pending.selected {
        sink.state.proxy = true;
        sink.state.upstream = pending.state;
        sink.selected = true;
        sink.input = pending.input;
        sink.duplex = pending.duplex;
        sink.defer_headers = pending.defer_headers;
        sink.pending_bytes_max = pending.pending_bytes_max;
    }
    return result;
}

// Called after asynchronous lookup. Explicitly keeps Portal's root-listing fallback.
// Applications can return ServePath with /index.html for an intentional SPA/index policy.
fn policy(event: silly::StaticLookupEvent) -> silly::StaticAction {
    return silly::default_static_policy(event);
}

fn step(state: Transfer&, event: silly::StreamEvent, out: silly::ChunkWriter&) -> silly::StreamStep {
    if state.proxy {
        return silly_client::proxy_step_with_policy(state.upstream, event, out,
            promptnook_portal::default_error, silly_client::default_proxy_inspect);
    }
    return silly::static_file_step_with_policy(state.file, event, out, silly::default_file_validator, policy);
}

fn lifecycle(app: AppState&, event: silly::Lifecycle<Route>) -> silly::HookResult {
    return silly::HookResult.Ok;
}

fn run(app: AppState&) -> silly::ServerResult {
    return silly::serve<Route, AppState, Transfer>(silly::ServerOptions {
            address: "127.0.0.1",
            port: 8082,
            ..
        }, app, routes, handle, step, lifecycle);
}

fn finish(executor: silly::FileExecutor&) -> bool {
    silly::stop_file_executor(executor);
    for turn in 10000 {
        let result = silly::finish_file_executor(executor);
        if result.complete {
            return true;
        }
        if result.error != 0 {
            return false;
        }
        const descriptors: i32[1] = [-1];
        const interests: i32[1] = [0];
        var events: i32[1] = [0];
        silly_transport::poll(descriptors, interests, events, 1);
    }
    return false;
}

fn finish_client(client: silly_client::Client&) -> bool {
    silly_client::stop_client(client);
    for turn in 10000 {
        let result = silly_client::finish_client(client);
        if result.complete {
            return true;
        }
        if result.error != silly_client::ClientError.None {
            return false;
        }
        const descriptors: i32[1] = [-1];
        const interests: i32[1] = [0];
        var events: i32[1] = [0];
        silly_transport::poll(descriptors, interests, events, 1);
    }
    return false;
}

fn::main() {
    var root = silly::open_file_root("./public");
    if !root.ok {
        print("Cannot open ./public: ", root.error);
        exit(1);
    }
    var executor = silly::start_file_executor();
    if !executor.ok {
        silly::close_file_root(root.root);
        exit(1);
    }
    var client = silly_client::start_client();
    if !client.ok {
        portal_reference::finish(executor.executor);
        silly::close_file_root(root.root);
        exit(1);
    }
    var app = portal_reference::AppState {
        root: root.root,
        executor: executor.executor,
        client: client.client
    };
    let result = portal_reference::run(app);
    let finished = portal_reference::finish(executor.executor);
    let client_finished = portal_reference::finish_client(client.client);
    silly::close_file_root(root.root);
    if !finished || !client_finished {
        print("Native shutdown still pending");
        exit(1);
    }
    if !result.ok {
        print(result.message);
        exit(1);
    }
}
