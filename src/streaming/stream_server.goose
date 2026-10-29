// Six-argument static serve binds endpoint, producer and lifecycle callbacks at compilation.
namespace silly;

import std;

import.stream_context;
import.stream_contract;
import.stream_driver;
import.stream_loop;
import.stream_transport;

fn serve<R, A, S, D, H, F, L>(options: ServerOptions, app: A&) -> ServerResult {
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
    if plan.issue.error != RouteError.None {
        return route_failure(plan.issue);
    }
    var listener = silly_transport::listen(options.address, options.port, 128);
    if listener.status != silly_transport::IoStatus.Ready {
        return ServerResult {
            ok: false,
            error: ServerError.Listen,
            message: "listen failed",
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
            ..
        };
    }
    let result = run_prepared_stream_server<R, A, S>(options, listener.descriptor, wake.reader, plan, app, H, F, L);
    silly_transport::close(wake.writer);
    return result;
}

// Consumes listener and wake reader. A wake requests cancellation on this single execution owner.
fn run_prepared_stream_server<R, A, S, H, F, L>(options: ServerOptions,
    listener: silly_transport::Descriptor, wake: silly_transport::Descriptor,
    plan: RoutePlan<R>, app: A&) -> ServerResult {
    var owned_listener = listener;
    var owned_wake = wake;
    if !valid_server_options(options) || listener.fd < 0 || wake.fd < 0 || listener.fd == wake.fd
        || plan.issue.error != RouteError.None {
        silly_transport::close(owned_listener);
        if listener.fd != wake.fd {
            silly_transport::close(owned_wake);
        }
        return ServerResult {
            ok: false,
            error: ServerError.InvalidOptions,
            message: "invalid stream server",
            ..
        };
    }
    var slots: StreamSlot<S>[>..] = [];
    slots.resize(options.connections_max, StreamSlot<S> {
        });
    var driver = StreamDriver<R, A, S> {
        lifecycle: LifecycleDriver<R,
        A> {
            plan: plan,
            app: app,
            ..
        },
        slots: slots,
        ..
    };
    fn dispatch(state: StreamDriver<R, A, S> & , ctx: BufferedContext&) {
        dispatch_stream_route(state, ctx, H);
    }

    fn observe(state: StreamDriver<R, A, S> & , event: ServerEvent) -> HookResult {
        return observe_stream_lifecycle(state, event, F, L);
    }

    fn drive_loop(storage: ServerStorage&, settings: ServerOptions, incoming: silly_transport::Descriptor,
        control: silly_transport::Descriptor, state: StreamDriver<R, A, S> & ) -> ServerResult {
        let result = stream_server_loop(storage, settings, incoming, control, state, dispatch, F, observe);
        for &slot in state.slots {
            cancel_stream_slot(slot, F);
        }
        return result;
    }
    var hooks = HookState {
    };
    observe_server(driver, hooks, ServerEvent.Start, observe);
    if hooks.failure != HookResult.Ok {
        observe_server(driver, hooks, ServerEvent.Stop, observe);
        silly_transport::close(owned_listener);
        silly_transport::close(owned_wake);
        return hook_server_result(hooks);
    }
    return run_server_storage_loop(options, owned_listener, owned_wake, driver, hooks,
        default_response_error, dispatch, observe, drive_loop);
}

fn dispatch_stream_route<R, A, S, H>(driver: StreamDriver<R, A, S> & , ctx: BufferedContext&) {
    let slot .= driver.slots[driver.current];
    slot.start = StreamStart<S> {
    };
    var typed = Context<A, S> {
        request: ctx.request,
        response: ctx.response,
        app: driver.lifecycle.app,
        stream_start: slot.start,
        audit: ctx.audit,
        route_captures: ctx.route_captures,
    };
    dispatch_route(driver.lifecycle.plan, typed, H);
}

fn observe_stream_lifecycle<R, A, S, F, L>(driver: StreamDriver<R, A, S> & ,
    event: ServerEvent) -> HookResult {
    if event == ServerEvent.Stop {
        for &slot in driver.slots {
            cancel_stream_slot(slot, F);
        }
    }
    return observe_lifecycle(driver.lifecycle, event, L);
}
