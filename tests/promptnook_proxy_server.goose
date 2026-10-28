// Consumer proxy server applies source-derived environment, header and audit policy.
namespace pn_server;

import client from "../client";
import portal_audit from "../examples/promptnook_contract";
import portal_proxy from "../examples/promptnook_contract";
import proxy from "../client";
import silly from "..";

import std;

import.promptnook_proxy_fixture;

struct App {
    client: silly_client::Client,
    plain: u8[..256] = [],
    secure: u8[..256] = [],
    refused: u8[..256] = [],
    mismatch: u8[..256] = [],
    fallback: u8[..256] = [],
}
struct Started {
    ok: bool = true
}
struct Stopped {
    ok: bool
}
enum Route {
    Proxy
}
type Context = silly::Context<App, silly_client::ProxyTransfer>;

fn handle(ctx: Context&, route: Route) {
    let environments = [
        promptnook_portal::Environment {
            name: "axiom",
            base_url: ctx.app.plain,
            token_configured: true,
            token: "configured-token"
        },
        promptnook_portal::Environment {
            name: "secure",
            base_url: ctx.app.secure,
            token_configured: true,
            token: "secure-token"
        },
        promptnook_portal::Environment {
            name: "incoming",
            base_url: ctx.app.plain,
            ..
        },
        promptnook_portal::Environment {
            name: "empty",
            base_url: ctx.app.plain,
            token_configured: true,
            ..
        },
        promptnook_portal::Environment {
            name: "refused",
            base_url: ctx.app.refused,
            ..
        },
        promptnook_portal::Environment {
            name: "mismatch",
            base_url: ctx.app.mismatch,
            ..
        }
    ];
    var config = promptnook_portal::Config {
        environments: environments,
        fallback_url: ctx.app.fallback,
        ..
    };
    if silly::header(ctx.request, "X-Test-Legacy").present {
        config.environments = environments[..0];
    }
    var prepared = promptnook_portal::prepare(ctx.request, config);
    var result = silly::ResponseError.None;
    if prepared.error != promptnook_portal::PortalError.None {
        let error = promptnook_portal::policy_response(prepared);
        result = silly::respond_text(ctx, error.status, error.body);
    } else {
        let inspect = starts_with(ctx.request.target, "/portal-api/audit");
        result = promptnook_portal::start(ctx, ctx.app.client, prepared, if inspect {
                32768
            } else {
                0
            },
            if inspect {
                19
            } else {
                0
            });
    }
    if result != silly::ResponseError.None {
        silly::fail_response(ctx.response, result);
    }
}

fn map_error(failure: silly_client::ProxyFailure) -> silly_client::ProxyErrorResponse {
    return promptnook_portal::transport_error(failure.error, "localhost", "test");
}

fn step(state: silly_client::ProxyTransfer&, event: silly::StreamEvent, out: silly::ChunkWriter&) -> silly::StreamStep {
    return silly_client::proxy_step_with_policy(state, event, out, map_error, inspect);
}

fn inspect(info: silly_client::ProxyInspection, head: silly_client::ClientResponse&, body: u8[:]) -> i32 {
    if info.tag == 19 {
        var audit = promptnook_portal::PortalAudit {
        };
        promptnook_portal::audit_response(audit, info, body);
        assert(audit.inspected);
        assert(!audit.limited);
        assert(audit.tag == 19);
        assert(audit.action.bytes == "lookup");
        assert(audit.target.bytes == "node-7");
        assert(audit.error_message.bytes == "safe error");
        assert(audit.error_code.bytes == "NOT_FOUND");
        assert(promptnook_portal::audit_outcome(audit.status) == "failure");
        return 202;
    }
    assert(!info.buffered);
    return 0;
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
    app.plain.append(str(pn_fixture::config(0), "/api/admin/?ignored=1"));
    app.secure.append(str(pn_fixture::config(1), "/secure/base/"));
    app.refused.append(pn_fixture::config(2));
    app.mismatch.append(pn_fixture::config(4));
    app.fallback.append(str(pn_fixture::config(0), "/legacy"));
    var entries: silly::RouteEntry<Route>[>..] = [];
    var segments: silly::RouteSegment[>..] = [];
    var bytes: u8[>..] = [];
    var router = silly::Router<Route> {
        entries: entries,
        segments: segments,
        bytes: bytes,
        ..
    };
    router.any("/portal-api", Route.Proxy, silly::RouteOptions {
            body: silly::BodyMode.Streamed,
            ..
        });
    router.any("/portal-api/*path", Route.Proxy, silly::RouteOptions {
            body: silly::BodyMode.Streamed,
            ..
        });
    let result = silly::run_prepared_stream_server<Route, App, silly_client::ProxyTransfer>(silly::ServerOptions {
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
