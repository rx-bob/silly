// Prepared route owners remain alive throughout the single-owner server loop.
namespace silly;

import std;

import.endpoint;
import.lifecycle_types;
import.response_errors;
import.route_captures;
import.route_match;
import.route_plan;
import.route_policy;
import.route_state_server;
import.route_types;
import.router;
import.server;
import.server_buffers;
import.server_options;
import.transport;

fn serve<R, D, H>(options: ServerOptions) -> ServerResult {
    return serve_with_errors<R>(options, D, H, default_response_error);
}

fn serve_with_errors<R, D, H, E>(options: ServerOptions) -> ServerResult {
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
    return serve_prepared_with_errors(options, plan, H, E);
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
    return serve_prepared_with_errors(options, plan, H, default_response_error);
}

fn serve_prepared_with_errors<R, H, E>(options: ServerOptions, plan: RoutePlan<R>) -> ServerResult {
    var app = NoState {
    };
    return serve_prepared_with_cleanup_and_errors(options, plan, app, H, endpoint_cleanup, E);
}

// Like run_server, consumes listener and wake; the caller retains immutable plan owners.
fn run_prepared_server<R, H>(options: ServerOptions, listener: silly_transport::Descriptor,
    wake: silly_transport::Descriptor, plan: RoutePlan<R>) -> ServerResult {
    return run_prepared_server_with_errors(options, listener, wake, plan, H, default_response_error);
}

fn run_prepared_server_with_errors<R, H, E>(options: ServerOptions, listener: silly_transport::Descriptor,
    wake: silly_transport::Descriptor, plan: RoutePlan<R>) -> ServerResult {
    var app = NoState {
    };
    return run_prepared_server_with_cleanup_and_errors(options, listener, wake, plan, app,
        H, endpoint_cleanup, E);
}

fn dispatch_route<R, A, S, H>(plan: RoutePlan<R>&, ctx: Context<A, S> & ) {
    dispatch_route_with_cleanup(plan, ctx, H, endpoint_cleanup);
}

fn dispatch_route_with_cleanup<R, A, S, H, C>(plan: RoutePlan<R>&, ctx: Context<A, S> & ) {
    let selected = match_route(plan, ctx.request.method, ctx.request.target);
    let audit = ctx.audit;
    if audit {
        audit.route_id = selected.route_id;
        audit.selection = if selected.result == RouteMatchResult.Matched {
            CompletionSelection.Matched
        } else if selected.result == RouteMatchResult.NotFound {
            CompletionSelection.NotFound
        } else if selected.result == RouteMatchResult.GeneratedOptions
            || selected.result == RouteMatchResult.MethodNotAllowed {
            CompletionSelection.Generated
        } else {
            CompletionSelection.Unavailable
        };
    }
    if selected.result == RouteMatchResult.Matched {
        var routed = Context<A, S> {
            request: ctx.request,
            response: ctx.response,
            app: ctx.app,
            stream_start: ctx.stream_start,
            audit: ctx.audit,
            route_captures: route_captures(plan, selected.route_id, ctx.request.target),
            ..
        };
        coordinate_endpoint(routed, plan.entries[selected.route_id].action, H, C);
    } else if selected.result == RouteMatchResult.GeneratedOptions
        || selected.result == RouteMatchResult.MethodNotAllowed {
        route_method_reply(plan, ctx, selected.result);
    } else if selected.result == RouteMatchResult.NotFound {
        route_empty_reply(ctx, 404);
    } else if selected.result == RouteMatchResult.PathLimit {
        route_empty_reply(ctx, 414);
    } else {
        route_empty_reply(ctx, 400);
    }
}

// Generated method responses use the ordinary bounded response builder and error renderer.
fn route_method_reply<R, A, S>(plan: RoutePlan<R>, ctx: Context<A, S> & , result: RouteMatchResult) {
    var allow: u8[>..] = [];
    let error = route_allow(allow, plan, ctx.request.target, ctx.response.limits.header_bytes_max);
    if error != ResponseError.None {
        fail_response(ctx.response, error);
        return;
    }
    let status: i32 = if result == RouteMatchResult.GeneratedOptions {
        204
    } else {
        405
    };
    if begin_response(ctx.response, status) != ResponseError.None {
        return;
    }
    if add_header(ctx.response, "Allow", allow) != ResponseError.None {
        return;
    }
    prepare_response(ctx.response);
}

fn route_empty_reply<A, S>(ctx: Context<A, S> & , status: i32) {
    if begin_response(ctx.response, status) == ResponseError.None {
        prepare_response(ctx.response);
    }
}
