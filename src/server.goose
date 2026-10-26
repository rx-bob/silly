// Minimal buffered server. Later router/serve adapters use this owner/transport path.
namespace silly;

import std;

import.connection;
import.server_loop;
import.server_options;
import.transport;

// Consumes listener and wake reader on every path; caller must relinquish its descriptor copies.
// A wake byte or closed wake peer requests immediate cancellation, not E6's graceful drain.
fn run_server<H>(options: ServerOptions, listener: silly_transport::Descriptor,
    wake: silly_transport::Descriptor) -> ServerResult {
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
    var connections: Connection[>..] = [];
    var input: u8[>..] = [];
    var head: u8[>..] = [];
    var body: u8[>..] = [];
    var fds: i32[>..] = [];
    var interests: i32[>..] = [];
    var events: i32[>..] = [];
    connections.resize(options.connections_max, Connection {
        });
    input.resize(options.connections_max * options.limits.head_bytes_max, 0);
    head.resize(options.connections_max * options.response_head_bytes_max, 0);
    body.resize(options.connections_max * options.limits.output_bytes_max, 0);
    fds.resize(options.connections_max + 2, -1);
    interests.resize(options.connections_max + 2, 0);
    events.resize(options.connections_max + 2, 0);
    var storage = ServerStorage {
        connections: connections,
        input: input,
        head: head,
        body: body,
        fds: fds,
        interests: interests,
        events: events,
    };
    let result = server_loop(storage, options, owned_listener, owned_wake, H);
    for &connection in connections {
        release_connection(connection);
    }
    silly_transport::close(owned_listener);
    silly_transport::close(owned_wake);
    return result;
}

// Initial low-level entry point: handles each admitted GET with one static callback.
// Startup Router<R> and the target serve<R> overloads are added by E3, not emulated here.
fn serve_buffered<H>(options: ServerOptions) -> ServerResult {
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
    let result = run_server(options, listener.descriptor, wake.reader, H);
    silly_transport::close(wake.writer);
    return result;
}
