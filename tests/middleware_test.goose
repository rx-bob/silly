// One guard boundary preserves entered-layer order and fixed audit ownership.
namespace middleware_test;

import audit from "../src";
import lifecycle_types from "../src";
import middleware from "../src";
import silly from "..";

import std;

struct App {
    reject_at: i64 = 0,
    continued: bool = false,
    fail_after: bool = false,
    log: u8[..128] = [],
}
struct StreamState {
    count: i64 = 0
}
type Context = silly::Context<App, StreamState>;
enum Route {
    Normal,
    Failed,
    Missing,
    Stream,
    BadAudit,
    StreamInput,
    Reentry
}

fn global_before(ctx: Context&, route: Route) {
    ctx.app.log.append("G");
    if ctx.app.reject_at == 1 {
        ctx.reject_text(401, "global");
    }
}

fn group_before(ctx: Context&, route: Route) {
    ctx.app.log.append("M");
    if ctx.app.reject_at == 2 {
        ctx.reject_text(403, "group");
    }
}

fn route_before(ctx: Context&, route: Route) {
    ctx.app.log.append("R");
    if ctx.app.reject_at == 3 {
        ctx.reject_text(403, "route");
    }
}

fn forbidden(ctx: Context&, route: Route) {
    abort("nested handler ran");
}

fn actual(ctx: Context&, route: Route) {
    ctx.app.log.append("H");
    if route == Route.Reentry {
        silly::middleware(ctx, Route.Normal, global_before, group_before, route_before, forbidden);
        abort("middleware reentry returned");
    } else if route == Route.Failed {
        silly::fail_response(ctx.response, silly::ResponseError.Application);
    } else if route == Route.Missing {
        return;
    } else if route == Route.BadAudit {
        let oversized: u8[129] = ['x'; 129];
        silly::audit_request_id(ctx, oversized);
        abort("audit limit returned");
    } else if route == Route.StreamInput {
        silly::audit_request_payload(ctx, 256);
        abort("streamed body capture returned");
    } else {
        var id: u8[>..] = str("request-", 7);
        silly::audit_request_id(ctx, id);
        id.clear();
        silly::audit_data(ctx, "chosen metadata");
        silly::audit_request_payload(ctx, 3);
        if route == Route.Stream {
            assert(silly::start_stream(ctx, 200, StreamState {
                }) == silly::ResponseError.None);
        } else {
            ctx.text(200, "response");
        }
        silly::audit_response_payload(ctx, 4);
    }
}

fn handle(ctx: Context&, route: Route) {
    silly::middleware(ctx, route, global_before, group_before, route_before, actual);
    ctx.app.continued = true;
}

fn global_after(app: App&, event: silly::Lifecycle<Route>) -> silly::HookResult {
    app.log.append("g");
    return silly::HookResult.Ok;
}

fn group_after(app: App&, event: silly::Lifecycle<Route>) -> silly::HookResult {
    app.log.append("m");
    return silly::HookResult.Ok;
}

fn route_after(app: App&, event: silly::Lifecycle<Route>) -> silly::HookResult {
    app.log.append("r");
    return if app.fail_after {
        silly::HookResult.Failed {
            message: "route completion failed"
        }
    } else {
        silly::HookResult.Ok
    };
}

fn verify(route: Route, reject_at: i64, expected: u8[:], fail_after: bool = false) {
    let payload: u8[300] = ['q'; 300];
    let request = silly::Request {
        method: "POST",
        target: "/api/item",
        body_state: if route == Route.StreamInput {
            silly::RequestBody.Streamed
        } else {
            silly::RequestBody.Buffered {
                bytes: payload
            }
        },
        ..
    };
    var fields: silly::HeaderField[>..] = [];
    var headers: u8[>..] = [];
    var output: u8[>..] = [];
    var response = silly::Response {
        limits: silly::Limits {
            output_bytes_max: 512,
            ..
        },
        header_fields: fields,
        header_bytes: headers,
        output: output,
        ..
    };
    var app = App {
        reject_at: reject_at,
        fail_after: fail_after,
        ..
    };
    var data = silly::CompletionData {
    };
    var pending = silly::StreamStart<StreamState> {
    };
    {
        var ctx = Context {
            request: request,
            response: response,
            app: app,
            stream_start: pending,
            audit: data,
            ..
        };
        silly::endpoint(ctx, route, handle);
    }
    let event: silly::Lifecycle<Route> = silly::Lifecycle<Route>.HandlerFinished {
        completion: silly::Completion<Route> {
            route: silly::CompletionRoute<Route>.Application {
                route: route
            },
            data: data,
        }
    };
    let result = silly::middleware_complete(app, event, global_after, group_after, route_after);
    assert(app.log == expected);
    assert((result != silly::HookResult.Ok) == fail_after);
    verify_capture(route, reject_at, app, data, response);
    if route == Route.Stream {
        assert(pending.selected);
    }
}

fn verify_capture(route: Route, reject_at: i64, app: App, data: silly::CompletionData,
    response: silly::Response&) {
    if reject_at != 0 || route == Route.BadAudit || route == Route.StreamInput || route == Route.Reentry {
        assert(!app.continued);
    } else {
        assert(app.continued);
    }
    if reject_at == 0 && (route == Route.Normal || route == Route.Stream) {
        assert(data.audit.request_id == "request-7");
        assert(data.audit.data == "chosen metadata");
        assert(data.audit.request_payload == "qqq");
        assert(data.audit.request_truncated);
        if route == Route.Normal {
            assert(data.audit.response_payload == "resp");
            assert(data.audit.response_truncated);
        } else {
            assert(response.output.len == 0);
            assert(data.audit.response_payload.len == 0);
        }
    }
    if route == Route.Failed || route == Route.BadAudit || route == Route.StreamInput || route == Route.Reentry {
        assert(response.phase == silly::ResponsePhase.Failed);
    }
    if route == Route.Missing {
        assert(response.phase == silly::ResponsePhase.Empty);
    }
}

fn::main() {
    middleware_test::verify(middleware_test::Route.Normal, 0, "GMRHrmg");
    middleware_test::verify(middleware_test::Route.Normal, 1, "Gg");
    middleware_test::verify(middleware_test::Route.Normal, 2, "GMmg");
    middleware_test::verify(middleware_test::Route.Normal, 3, "GMRrmg");
    middleware_test::verify(middleware_test::Route.Failed, 0, "GMRHrmg");
    middleware_test::verify(middleware_test::Route.Missing, 0, "GMRHrmg");
    middleware_test::verify(middleware_test::Route.Stream, 0, "GMRHrmg");
    middleware_test::verify(middleware_test::Route.BadAudit, 0, "GMRHrmg");
    middleware_test::verify(middleware_test::Route.StreamInput, 0, "GMRHrmg");
    middleware_test::verify(middleware_test::Route.Normal, 0, "GMRHrmg", true);
    middleware_test::verify(middleware_test::Route.Reentry, 0, "GMRHrmg");
    print("middleware order, guards and bounded audit passed");
}
