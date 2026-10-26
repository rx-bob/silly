// Prepared route owners remain alive throughout the single-owner server loop.
namespace silly;

import std;

import.route_match;
import.route_plan;
import.route_types;
import.router;
import.server;
import.server_buffers;
import.server_options;
import.transport;

fn serve<R, D, H>(options: ServerOptions) -> ServerResult {
    if !valid_server_options(options) {
        return ServerResult {
            ok: false,
            error: ServerError.InvalidOptions,
            message: "invalid server options",
            ..
        };
    }
    var entries: RouteEntry<R>[>..] = [];
    var segments: RouteSegment[>..] = [];
    var bytes: u8[>..] = [];
    var router = Router<R> {
        entries: entries,
        segments: segments,
        bytes: bytes,
        limits: options.route_limits,
        ..
    };
    D(router);
    let plan = prepare(router);
    if plan.issue.error != RouteError.None {
        return route_failure(plan.issue);
    }
    return serve_prepared(options, plan, H);
}

fn route_failure(issue: RouteIssue) -> ServerResult {
    return ServerResult {
        ok: false,
        error: ServerError.Routes,
        message: "invalid route declarations; see route_issue",
        route_issue: issue,
        ..
    };
}

fn serve_prepared<R, H>(options: ServerOptions, plan: RoutePlan<R>) -> ServerResult {
    if !valid_server_options(options) {
        return ServerResult {
            ok: false,
            error: ServerError.InvalidOptions,
            message: "invalid server options",
            ..
        };
    }
    if plan.issue.error != RouteError.None {
        return route_failure(plan.issue);
    }
    var listener = silly_transport::listen(options.address, options.port, 128);
    if listener.status != silly_transport::IoStatus.Ready {
        return ServerResult {
            ok: false,
            error: ServerError.Listen,
            message: "listen failed",
            system_error: listener.error,
            ..
        };
    }
    var wake = silly_transport::wake_pair();
    if wake.status != silly_transport::IoStatus.Ready {
        silly_transport::close(listener.descriptor);
        return ServerResult {
            ok: false,
            error: ServerError.Wake,
            message: "wake failed",
            system_error: wake.error,
            ..
        };
    }
    let result = run_prepared_server(options, listener.descriptor, wake.reader, plan, H);
    silly_transport::close(wake.writer);
    return result;
}

// Like run_server, consumes listener and wake; the caller retains immutable plan owners.
fn run_prepared_server<R, H>(options: ServerOptions, listener: silly_transport::Descriptor,
    wake: silly_transport::Descriptor, plan: RoutePlan<R>) -> ServerResult {
    var driver = plan;
    if plan.issue.error != RouteError.None {
        var owned_listener = listener;
        var owned_wake = wake;
        silly_transport::close(owned_listener);
        if listener.fd != wake.fd {
            silly_transport::close(owned_wake);
        }
        return route_failure(plan.issue);
    }
    return run_server_state(options, listener, wake, driver) {
        routes,
        ctx => dispatch_route(routes, ctx, H)
    };
}

fn dispatch_route<R, H>(plan: RoutePlan<R>&, ctx: BufferedContext&) {
    let selected = match_route(plan, ctx.request.method, ctx.request.target);
    if selected.result == RouteMatchResult.Matched {
        H(ctx, plan.entries[selected.route_id].action);
    } else if selected.result == RouteMatchResult.NotFound {
        empty_reply(ctx, 404);
    } else if selected.result == RouteMatchResult.PathLimit {
        empty_reply(ctx, 414);
    } else {
        empty_reply(ctx, 400);
    }
}
