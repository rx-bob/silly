// Static lifecycle adapters reconstruct typed routes from retained immutable route plans.
namespace silly;

import std;

import.context;
import.lifecycle_driver;
import.lifecycle_types;
import.response_errors;
import.route_plan;
import.route_server;
import.route_types;
import.router;
import.server;
import.server_buffers;
import.server_options;
import.transport;

fn route_completion<R, A>(driver: LifecycleDriver<R, A> & , data: CompletionData) -> Completion<R> {
    var route: CompletionRoute<R> = CompletionRoute<R>.Unavailable {
    };
    if data.selection == CompletionSelection.Matched && data.route_id >= 0 && data.route_id < driver.plan.entries.len {
        route = CompletionRoute<R>.Application {
            route: driver.plan.entries[data.route_id].action
        };
    } else if data.selection == CompletionSelection.Generated {
        route = CompletionRoute<R>.Generated {
        };
    } else if data.selection == CompletionSelection.NotFound {
        route = CompletionRoute<R>.NotFound {
        };
    }
    return Completion<R> {
        route: route,
        data: data
    };
}

fn observe_lifecycle<R, A, L>(driver: LifecycleDriver<R, A> & , event: ServerEvent) -> HookResult {
    match event {
        Start => {
            return L(driver.app, Lifecycle<R>.Start {
                    owner: driver.owner
                });
        },
        HandlerFinished done => {
            return L(driver.app, Lifecycle<R>.HandlerFinished {
                    completion: route_completion(driver, done.completion)
                });
        },
        TransferFinished done => {
            return L(driver.app, Lifecycle<R>.TransferFinished {
                    completion: route_completion(driver, done.completion)
                });
        },
        Stop => {
            return L(driver.app, Lifecycle<R>.Stop {
                    owner: driver.owner
                });
        },
    }
}

fn dispatch_lifecycle_route<R, A, H>(driver: LifecycleDriver<R, A> & , ctx: BufferedContext&) {
    var typed = Context<A, NoStream> {
        request: ctx.request,
        response: ctx.response,
        app: driver.app,
        stream_start: ctx.stream_start,
        audit: ctx.audit,
        route_captures: ctx.route_captures,
    };
    dispatch_route(driver.plan, typed, H);
}

fn run_prepared_server_with_lifecycle<R, A, H, L>(options: ServerOptions,
    listener: silly_transport::Descriptor, wake: silly_transport::Descriptor,
    plan: RoutePlan<R>, app: A&) -> ServerResult {
    return run_prepared_server_with_lifecycle_and_errors(options, listener, wake, plan, app,
        H, L, default_response_error);
}

fn run_prepared_server_with_lifecycle_and_errors<R, A, H, L, E>(options: ServerOptions,
    listener: silly_transport::Descriptor, wake: silly_transport::Descriptor,
    plan: RoutePlan<R>, app: A&) -> ServerResult {
    if plan.issue.error != RouteError.None {
        var owned_listener = listener;
        var owned_wake = wake;
        silly_transport::close(owned_listener);
        if listener.fd != wake.fd {
            silly_transport::close(owned_wake);
        }
        return route_failure(plan.issue);
    }
    var driver = LifecycleDriver<R, A> {
        plan: plan,
        app: app,
        ..
    };
    fn dispatch(routes: LifecycleDriver<R, A> & , ctx: BufferedContext&) {
        dispatch_lifecycle_route(routes, ctx, H);
    }

    fn observe(routes: LifecycleDriver<R, A> & , event: ServerEvent) -> HookResult {
        return observe_lifecycle(routes, event, L);
    }
    return run_server_state_with_observer(options, listener, wake, driver, E, dispatch, observe);
}

// Five call-site arguments: options, app, startup routes, endpoint and lifecycle callbacks.
fn serve<R, A, D, H, L>(options: ServerOptions, app: A&) -> ServerResult {
    return serve_with_lifecycle_and_errors<R>(options, app, D, H, L, default_response_error);
}

fn serve_with_lifecycle_and_errors<R, A, D, H, L, E>(options: ServerOptions, app: A&) -> ServerResult {
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
    return serve_prepared_with_lifecycle_and_errors(options, plan, app, H, L, E);
}

fn serve_prepared_with_lifecycle<R, A, H, L>(options: ServerOptions, plan: RoutePlan<R>, app: A&) -> ServerResult {
    return serve_prepared_with_lifecycle_and_errors(options, plan, app, H, L, default_response_error);
}

fn serve_prepared_with_lifecycle_and_errors<R, A, H, L, E>(options: ServerOptions,
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
    let result = run_prepared_server_with_lifecycle_and_errors(options, listener.descriptor,
        wake.reader, plan, app, H, L, E);
    silly_transport::close(wake.writer);
    return result;
}
