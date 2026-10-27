// Combined public static/proxy server with disposable configuration.
namespace portal_integration;

import client from "../client";
import portal_proxy from "../examples/promptnook_contract";
import proxy from "../client";
import silly from "..";

import std;

import.static_portal_server;

struct AppState {
    executor: silly::FileExecutor,
    root: silly::FileRoot,
    client: silly_client::Client,
    upstream_url: u8[..128] = [],
    refused_url: u8[..128] = [],
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
            body_bytes_max: 4096,
            ..
        });
    router.any("/portal-api/*path", Route.Proxy, silly::RouteOptions {
            body: silly::BodyMode.Streamed,
            body_bytes_max: 4096,
            ..
        });
    router.get("/*path", Route.Static);
    router.head("/*path", Route.Static);
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
    let environments = [promptnook_portal::Environment {
            name: "axiom",
            base_url: ctx.app.upstream_url,
            token_configured: true,
            token: "fixture-token",
            ..
        }, promptnook_portal::Environment {
            name: "refused",
            base_url: ctx.app.refused_url,
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
    let cancelled = event == silly::StreamEvent.Cancelled && state.proxy
        && !state.upstream.done && !state.upstream.failed;
    let result = if state.proxy {
        silly_client::proxy_step_with_policy(state.upstream, event, out,
            promptnook_portal::default_error, silly_client::default_proxy_inspect)
    } else {
        silly::static_file_step_with_policy(state.file, event, out, portal_server::validator, policy)
    };
    if cancelled {
        assert(qput(Cancelled {
                proxy: true
            }));
    }
    return result;
}

struct Cancelled {
    proxy: bool
}
struct Started {
    ok: bool = true
}
struct Stopped {
    ok: bool
}
struct Completed {
    proxy: bool,
    status: i32
}

fn lifecycle(app: AppState&, event: silly::Lifecycle<Route>) -> silly::HookResult {
    match event {
        Start _ => {
            assert(qput(Started {
                }));
        },
        TransferFinished done => {
            assert(qput(Completed {
                    proxy: match done.completion.route {
                        Application selected => selected.route == Route.Proxy,
                        _ => false,
                    },
                    status: done.completion.data.status
                }));
        },
        _ => {
        },
    }
    return silly::HookResult.Ok;
}
thread_fn server(listener: i32, wake: i32, initial: AppState) {
    var app = initial;
    var entries: silly::RouteEntry<Route>[>..] = [];
    var segments: silly::RouteSegment[>..] = [];
    var bytes: u8[>..] = [];
    var router = silly::Router<Route> {
        entries: entries,
        segments: segments,
        bytes: bytes,
        ..
    };
    routes(router, app);
    let result = silly::run_prepared_stream_server<Route, AppState, Transfer>(silly::ServerOptions {
            limits: silly::Limits {
                body_bytes_max: 4096,
                ..
            },
            work_bytes_per_turn: 1024,
            poll_timeout_ms: 10,
            ..
        }, silly_transport::Descriptor {
            fd: listener
        }, silly_transport::Descriptor {
            fd: wake
        },
        silly::prepare(router), app, handle, step, lifecycle);
    assert(qput(Stopped {
            ok: result.ok
        }));
}
