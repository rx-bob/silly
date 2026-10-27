namespace proxy_server;

import client from "../client";
import proxy from "../client";
import silly from "..";

import std;

import.proxy_fixture;

struct App {
    client: silly_client::Client,
    upstream: u8[..128] = [],
    refused: u8[..128] = [],
    stall: u8[..128] = [],
}
enum Route {
    Proxy,
    Buffered,
    Stats
}
struct Started {
    ok: bool = true
}
struct Stopped {
    ok: bool
}
type Context = silly::Context<App, silly_client::ProxyTransfer>;

fn target(ctx: Context&, options: silly_client::ProxyOptions&) -> u8[>..] {
    let value = ctx.request.target;
    var path: u8[>..] = [];
    if starts_with(value, "/incoming/") {
        options.authorization = silly_client::ProxyAuthorization.Incoming;
        options.host = silly_client::ProxyHost.Incoming;
        path.append(value[9..]);
    } else if starts_with(value, "/override/") {
        options.authorization = silly_client::ProxyAuthorization.Override;
        options.authorization_value = "Bearer supplied";
        options.host = silly_client::ProxyHost.Override;
        options.host_value = "custom.upstream";
        path.append(value[9..]);
    } else if starts_with(value, "/auto/") {
        options.decoding = silly_client::ContentDecoding.Automatic;
        path.append(value[5..]);
    } else if value == "/audit" {
        options.inspection_bytes_max = 128;
        options.tag = 1;
        path.append("/audit");
    } else if value == "/cap" {
        options.inspection_bytes_max = 8;
        path.append("/large");
    } else if value == "/mapped" {
        options.tag = 2;
        return str(ctx.app.refused, "/");
    } else if value == "/connect-stall" {
        return str(ctx.app.stall, "/");
    } else if starts_with(value, "/rewrite/") {
        path.append("/echo/");
        path.append(value[9..]);
    } else if value == "/buffered" {
        path.append("/echo");
    } else {
        path.append(value);
    }
    return str(ctx.app.upstream, path);
}

fn handle(ctx: Context&, route: Route) {
    if route == Route.Stats {
        let stats = str(proxy_fixture::silly_proxy_stat(0, 1), ",", proxy_fixture::silly_proxy_stat(1, 1),
            ",", proxy_fixture::silly_proxy_stat(2, 0));
        assert(silly::respond_text(ctx, 200, stats) == silly::ResponseError.None);
        return;
    }
    const overrides = [silly_client::RequestHeader {
            name: "X-Override",
            value: "configured"
        }];
    var options = silly_client::ProxyOptions {
        client: ctx.app.client,
        headers: overrides,
        pending_bytes_max: 257,
        ..
    };
    let url = target(ctx, options);
    options.target_url = url;
    let result = silly_client::proxy_response(ctx, options);
    if result != silly::ResponseError.None {
        silly::fail_response(ctx.response, result);
    }
}

fn map_error(failure: silly_client::ProxyFailure) -> silly_client::ProxyErrorResponse {
    var result = silly_client::ProxyErrorResponse {
    };
    result.status = if failure.tag == 2 {
        599
    } else {
        502
    };
    result.body.append(if failure.tag == 2 {
            "mapped failure"
        } else {
            "upstream failure"
        });
    result.content_type.append("text/plain");
    return result;
}

fn inspect(info: silly_client::ProxyInspection, head: silly_client::ClientResponse&, bytes: u8[:]) -> i32 {
    proxy_fixture::silly_proxy_inspected(info.tag as i64, bytes.len);
    if info.tag == 1 {
        assert(info.buffered);
        assert(bytes == "audited");
        assert(head.status_code == 200);
        return 201;
    }
    assert(!info.buffered || bytes.len <= 32768);
    return 0;
}

fn step(state: silly_client::ProxyTransfer&, event: silly::StreamEvent, out: silly::ChunkWriter&) -> silly::StreamStep {
    if event == silly::StreamEvent.Cancelled {
        proxy_fixture::silly_proxy_cancelled();
    }
    return silly_client::proxy_step_with_policy(state, event, out, map_error, inspect);
}

fn lifecycle(app: App&, event: silly::Lifecycle<Route>) -> silly::HookResult {
    match event {
        Start _ => {
            assert(qput(Started {
                }));
        },
        _ => {
        }
    }
    return silly::HookResult.Ok;
}

thread_fn server(listener: i32, wake: i32, client: silly_client::Client) {
    var app = App {
        client: client,
        ..
    };
    var config: u8[128] = [0; 128];
    let upstream = proxy_fixture::silly_proxy_config(0, config);
    assert(upstream > 0);
    app.upstream.append(config[..upstream]);
    let refused = proxy_fixture::silly_proxy_config(1, config);
    assert(refused > 0);
    app.refused.append(config[..refused]);
    let stall = proxy_fixture::silly_proxy_config(2, config);
    assert(stall > 0);
    app.stall.append(config[..stall]);
    var entries: silly::RouteEntry<Route>[>..] = [];
    var segments: silly::RouteSegment[>..] = [];
    var bytes: u8[>..] = [];
    var router = silly::Router<Route> {
        entries: entries,
        segments: segments,
        bytes: bytes,
        ..
    };
    router.get("/__stats", Route.Stats);
    router.post("/buffered", Route.Buffered);
    router.any("/*path", Route.Proxy, silly::RouteOptions {
            body: silly::BodyMode.Streamed,
            body_bytes_max: 4 * 1024 * 1024,
            ..
        });
    let result = silly::run_prepared_stream_server<Route, App, silly_client::ProxyTransfer>(silly::ServerOptions {
            limits: silly::Limits {
                body_bytes_max: 1024,
                output_bytes_max: 256,
                ..
            },
            connections_max: 4,
            work_bytes_per_turn: 257,
            accepts_per_turn: 4,
            dispatches_per_turn: 4,
            poll_timeout_ms: 10,
            body_limits: silly::BodyLimits {
                bytes_max: 4 * 1024 * 1024,
                ..
            },
            body_read_bytes_max: 257,
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
