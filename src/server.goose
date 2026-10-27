// Buffered single-owner transport shared by direct callbacks and prepared route dispatch.
namespace silly;

import std;

import.connection;
import.lifecycle_types;
import.response_errors;
import.server_buffers;
import.server_loop;
import.server_observer;
import.server_options;
import.state;
import.transport;

// Consumes listener and wake reader on every path; caller must relinquish its descriptor copies.
// A wake byte or closed wake peer requests immediate cancellation, not E6's graceful drain.
fn run_server<H>(options: ServerOptions, listener: silly_transport::Descriptor,
    wake: silly_transport::Descriptor) -> ServerResult {
    return run_server_with_errors(options, listener, wake, H, default_response_error);
}

fn run_server_with_errors<H, E>(options: ServerOptions, listener: silly_transport::Descriptor,
    wake: silly_transport::Descriptor) -> ServerResult {
    var driver = NoState {
    };
    return run_server_state_with_errors(options, listener, wake, driver, E) {
        state,
        ctx =>
        if ctx.request.method != "GET" {
            empty_reply(ctx, 501);
        } else {
            H(ctx);
        }
    };
}

fn run_server_state<D, H>(options: ServerOptions, listener: silly_transport::Descriptor,
    wake: silly_transport::Descriptor, driver: D&) -> ServerResult {
    return run_server_state_with_errors(options, listener, wake, driver, default_response_error, H);
}

fn run_server_state_with_errors<D, E, H>(options: ServerOptions, listener: silly_transport::Descriptor,
    wake: silly_transport::Descriptor, driver: D&) -> ServerResult {
    return run_server_state_with_observer(options, listener, wake, driver, E, H, no_server_observer);
}

fn run_server_state_with_observer<D, E, H, O>(options: ServerOptions, listener: silly_transport::Descriptor,
    wake: silly_transport::Descriptor, driver: D&) -> ServerResult {
    var owned_listener = listener;
    var owned_wake = wake;
    if !valid_server_options(options) || listener.fd < 0 || wake.fd < 0 || listener.fd == wake.fd {
        silly_transport::close(owned_listener);
        if owned_wake.fd != listener.fd {
            silly_transport::close(owned_wake);
        }
        return ServerResult {
            ok: false,
            error: ServerError.InvalidOptions,
            message: "invalid server options",
            ..
        };
    }
    var hooks = HookState {
    };
    observe_server(driver, hooks, ServerEvent.Start, O);
    if hooks.failure != HookResult.Ok {
        observe_server(driver, hooks, ServerEvent.Stop, O);
        silly_transport::close(owned_listener);
        silly_transport::close(owned_wake);
        return hook_server_result(hooks);
    }
    return run_server_storage(options, owned_listener, owned_wake, driver, hooks, E, H, O);
}

fn run_server_storage<D, E, H, O>(options: ServerOptions, listener: silly_transport::Descriptor,
    wake: silly_transport::Descriptor, driver: D&, hooks: HookState&) -> ServerResult {
    var owned_listener = listener;
    var owned_wake = wake;
    var connections: Connection[>..] = [];
    var input: u8[>..] = [];
    var head: u8[>..] = [];
    var body: u8[>..] = [];
    var request: u8[>..] = [];
    var staging: u8[>..] = [];
    var fds: i32[>..] = [];
    var interests: i32[>..] = [];
    var events: i32[>..] = [];
    connections.resize(options.connections_max, Connection {
        });
    input.resize(options.connections_max * options.limits.head_bytes_max, 0);
    head.resize(options.connections_max * options.response_head_bytes_max, 0);
    body.resize(options.connections_max * options.limits.output_bytes_max, 0);
    request.resize(options.connections_max * options.limits.body_bytes_max, 0);
    staging.resize(options.connections_max * server_read_bytes(options), 0);
    fds.resize(options.connections_max + 2, -1);
    interests.resize(options.connections_max + 2, 0);
    events.resize(options.connections_max + 2, 0);
    var storage = ServerStorage {
        connections: connections,
        input: input,
        head: head,
        body: body,
        request: request,
        staging: staging,
        fds: fds,
        interests: interests,
        events: events,
        hooks: hooks,
    };
    let result = server_loop(storage, options, owned_listener, owned_wake, driver, H, E, O);
    for &connection in connections {
        finish_transfer(connection, driver, hooks, TransferOutcome.Cancelled, O);
        release_connection(connection);
    }
    observe_server(driver, hooks, ServerEvent.Stop, O);
    silly_transport::close(owned_listener);
    silly_transport::close(owned_wake);
    return if hooks.failure == HookResult.Ok {
        result
    } else {
        hook_server_result(hooks)
    };
}

// Initial low-level entry point: handles each admitted GET with one static callback.
// Prepared Router<R> applications use serve<R> in route_server.goose.
fn serve_buffered<H>(options: ServerOptions) -> ServerResult {
    return serve_buffered_with_errors(options, H, default_response_error);
}

fn serve_buffered_with_errors<H, E>(options: ServerOptions) -> ServerResult {
    if !valid_server_options(options) {
        return ServerResult {
            ok: false,
            error: ServerError.InvalidOptions,
            message: "invalid server options",
            ..
        };
    }
    var listener = silly_transport::listen(options.address, options.port, 128);
    if listener.status != silly_transport::IoStatus.Ready {
        return ServerResult {
            ok: false,
            error: ServerError.Listen,
            message: "listen failed",
            system_error: listener.error
        };
    }
    var wake = silly_transport::wake_pair();
    if wake.status != silly_transport::IoStatus.Ready {
        silly_transport::close(listener.descriptor);
        return ServerResult {
            ok: false,
            error: ServerError.Wake,
            message: "wake failed",
            system_error: wake.error
        };
    }
    let result = run_server_with_errors(options, listener.descriptor, wake.reader, H, E);
    silly_transport::close(wake.writer);
    return result;
}
