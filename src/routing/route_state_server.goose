// Typed application state and endpoint cleanup share the existing buffered server loop.
namespace silly;

import std;

import.route_driver;
import.route_plan;
import.route_server;
import.route_types;
import.router;

fn serve<R, A, D, H>(options: ServerOptions, app: A&) -> ServerResult {
    return serve_with_cleanup_and_errors<R>(options, app, D, H, endpoint_cleanup, default_response_error);
}

fn serve_with_cleanup<R, A, D, H, C>(options: ServerOptions, app: A&) -> ServerResult {
    return serve_with_cleanup_and_errors<R>(options, app, D, H, C, default_response_error);
}

fn serve_with_errors<R, A, D, H, E>(options: ServerOptions, app: A&) -> ServerResult {
    return serve_with_cleanup_and_errors<R>(options, app, D, H, endpoint_cleanup, E);
}

fn serve_with_cleanup_and_errors<R, A, D, H, C, E>(options: ServerOptions, app: A&) -> ServerResult {
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
    D(router, app);
    let plan = prepare(router);
    return serve_prepared_with_cleanup_and_errors(options, plan, app, H, C, E);
}

fn serve_prepared<R, A, H>(options: ServerOptions, plan: RoutePlan<R>, app: A&) -> ServerResult {
    return serve_prepared_with_cleanup_and_errors(options, plan, app, H, endpoint_cleanup, default_response_error);
}

fn serve_prepared_with_cleanup<R, A, H, C>(options: ServerOptions,
    plan: RoutePlan<R>, app: A&) -> ServerResult {
    return serve_prepared_with_cleanup_and_errors(options, plan, app, H, C, default_response_error);
}

fn serve_prepared_with_errors<R, A, H, E>(options: ServerOptions, plan: RoutePlan<R>, app: A&) -> ServerResult {
    return serve_prepared_with_cleanup_and_errors(options, plan, app, H, endpoint_cleanup, E);
}

fn serve_prepared_with_cleanup_and_errors<R, A, H, C, E>(options: ServerOptions,
    plan: RoutePlan<R>, app: A&) -> ServerResult {
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
    let result = run_prepared_server_with_cleanup_and_errors(options, listener.descriptor,
        wake.reader, plan, app, H, C, E);
    silly_transport::close(wake.writer);
    return result;
}

// Consumes listener and wake. State and immutable route owners remain caller-owned.
fn run_prepared_server<R, A, H>(options: ServerOptions, listener: silly_transport::Descriptor,
    wake: silly_transport::Descriptor, plan: RoutePlan<R>, app: A&) -> ServerResult {
    return run_prepared_server_with_cleanup_and_errors(options, listener, wake, plan, app,
        H, endpoint_cleanup, default_response_error);
}

fn run_prepared_server_with_cleanup<R, A, H, C>(options: ServerOptions, listener: silly_transport::Descriptor,
    wake: silly_transport::Descriptor, plan: RoutePlan<R>, app: A&) -> ServerResult {
    return run_prepared_server_with_cleanup_and_errors(options, listener, wake, plan, app,
        H, C, default_response_error);
}

fn run_prepared_server_with_errors<R, A, H, E>(options: ServerOptions, listener: silly_transport::Descriptor,
    wake: silly_transport::Descriptor, plan: RoutePlan<R>, app: A&) -> ServerResult {
    return run_prepared_server_with_cleanup_and_errors(options, listener, wake, plan, app,
        H, endpoint_cleanup, E);
}

fn run_prepared_server_with_cleanup_and_errors<R, A, H, C, E>(options: ServerOptions,
    listener: silly_transport::Descriptor, wake: silly_transport::Descriptor,
    plan: RoutePlan<R>, app: A&) -> ServerResult {
    var driver = RouteDriver<R, A> {
        plan: plan,
        app: app
    };
    if plan.issue.error != RouteError.None {
        var owned_listener = listener;
        var owned_wake = wake;
        silly_transport::close(owned_listener);
        if listener.fd != wake.fd {
            silly_transport::close(owned_wake);
        }
        return route_failure(plan.issue);
    }
    return run_server_state_with_errors(options, listener, wake, driver, E) {
        routes,
        ctx => dispatch_state_route(routes, ctx, H, C)
    };
}

fn dispatch_state_route<R, A, H, C>(driver: RouteDriver<R, A> & , ctx: BufferedContext&) {
    var typed = Context<A, NoStream> {
        request: ctx.request,
        response: ctx.response,
        app: driver.app,
        audit: ctx.audit,
        route_captures: ctx.route_captures,
        stream_start: ctx.stream_start,
    };
    dispatch_route_with_cleanup(driver.plan, typed, H, C);
}
