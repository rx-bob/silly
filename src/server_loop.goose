// Poll-driven single-owner loop over fixed descriptors and bounded, nonmoving byte slabs.
namespace silly;

import std;

import.connection;
import.lifecycle_types;
import.server_body;
import.server_io;
import.server_observer;
import.server_options;
import.server_request_errors;
import.transport;

struct ServerStorage {
    connections: Connection[:],
    input: u8[:],
    head: u8[:],
    body: u8[:],
    request: u8[:],
    staging: u8[:],
    fds: i32[:],
    interests: i32[:],
    events: i32[:],
    hooks: HookState&,
}

fn server_loop<D, H, E, O>(storage: ServerStorage&, options: ServerOptions,
    listener: silly_transport::Descriptor, wake: silly_transport::Descriptor, driver: D&) -> ServerResult {
    var running = true;
    while running {
        if storage.hooks.failure != HookResult.Ok {
            return hook_server_result(storage.hooks);
        }
        prepare_poll(storage, listener, wake);
        let timeout = server_poll_timeout(storage, options);
        let ready = silly_transport::poll(storage.fds, storage.interests, storage.events, timeout);
        if ready.status == silly_transport::IoStatus.Interrupted {
            continue;
        }
        if ready.status != silly_transport::IoStatus.Ready {
            return ServerResult {
                ok: false,
                error: ServerError.Poll,
                message: "poll failed",
                system_error: ready.error
            };
        }
        let clock = silly_transport::monotonic_ms();
        if clock.status != silly_transport::IoStatus.Ready {
            return ServerResult {
                ok: false,
                error: ServerError.Clock,
                message: "clock failed",
                system_error: clock.error
            };
        }
        if storage.events[1] != 0 {
            running = false;
            continue;
        }
        if (storage.events[0] & (silly_transport::CLOSED | silly_transport::ERROR)) != 0 {
            return ServerResult {
                ok: false,
                error: ServerError.Listen,
                message: "listener failed",
                ..
            };
        }
        if (storage.events[0] & silly_transport::READ) != 0 {
            let accepted = accept_connections(storage.connections, listener, options, clock.count);
            if accepted.status != silly_transport::IoStatus.Ready
                && accepted.status != silly_transport::IoStatus.WouldBlock
                && accepted.status != silly_transport::IoStatus.Interrupted {
                return ServerResult {
                    ok: false,
                    error: ServerError.Accept,
                    message: "accept failed",
                    system_error: accepted.error
                };
            }
        }
        service_connections(storage, options, clock.count, driver, H, E, O);
    }
    return ServerResult {
        ok: true,
        ..
    };
}

fn prepare_poll(storage: ServerStorage&, listener: silly_transport::Descriptor, wake: silly_transport::Descriptor) {
    storage.fds[0] = listener.fd;
    storage.interests[0] = if available_connection(storage.connections) >= 0 {
        silly_transport::READ
    } else {
        0
    };
    storage.fds[1] = wake.fd;
    storage.interests[1] = silly_transport::READ;
    for index in storage.connections.len {
        let connection .= storage.connections[index];
        storage.fds[index + 2] = connection.socket.fd;
        storage.interests[index + 2] = match connection.phase {
            Free => {
                0
            },
            Reading => {
                silly_transport::READ
            },
            ReadingBody => {
                silly_transport::READ
            },
            Continue => {
                silly_transport::WRITE
            },
            Writing => {
                silly_transport::WRITE
            },
        };
    }
}

fn accept_connections(connections: Connection[:], listener: silly_transport::Descriptor,
    options: ServerOptions, now: i64) -> silly_transport::IoResult {
    for attempt in options.accepts_per_turn {
        let index = available_connection(connections);
        if index < 0 {
            return silly_transport::IoResult {
                status: silly_transport::IoStatus.Ready,
                ..
            };
        }
        let result = silly_transport::accept(listener);
        if result.status != silly_transport::IoStatus.Ready {
            return silly_transport::IoResult {
                status: result.status,
                error: result.error,
                ..
            };
        }
        let generation = connections[index].generation + 1;
        connections[index] = Connection {
            socket: result.descriptor,
            generation: generation,
            phase: ConnectionPhase.Reading,
            active_ms: now,
            ..
        };
    }
    return silly_transport::IoResult {
        status: silly_transport::IoStatus.Ready,
        ..
    };
}

fn service_connections<D, H, E, O>(storage: ServerStorage&, options: ServerOptions, now: i64, driver: D&) {
    for index in storage.connections.len {
        if storage.hooks.failure != HookResult.Ok {
            return;
        }
        let connection .= storage.connections[index];
        if connection.phase == ConnectionPhase.Free {
            continue;
        }
        if now < connection.active_ms || now - connection.active_ms >= options.idle_timeout_ms {
            request_timeout(connection, connection_buffers(storage, options, index), options, E);
            if connection.phase == ConnectionPhase.Free {
                finish_transfer(connection, driver, storage.hooks, TransferOutcome.Cancelled, O);
            }
            connection.active_ms = now;
            continue;
        }
        let events = storage.events[index + 2];
        if events == 0 && !input_pending(connection) {
            continue;
        }
        let buffers = connection_buffers(storage, options, index);
        let received_before = connection.received_bytes;
        let staged_before = connection.staged_read;
        let output_before = connection.head_sent + connection.body_sent;
        let phase_before = connection.phase;
        if connection.phase == ConnectionPhase.Reading || connection.phase == ConnectionPhase.ReadingBody {
            read_connection(connection, buffers, options, driver, H, E, O);
        } else {
            write_connection_observed(connection, buffers.head, buffers.body, options.work_bytes_per_turn,
                driver, storage.hooks, O);
        }
        if connection.phase == ConnectionPhase.Free {
            finish_transfer(connection, driver, storage.hooks, TransferOutcome.Cancelled, O);
        }
        if connection.received_bytes != received_before || connection.staged_read != staged_before
            || connection.head_sent + connection.body_sent != output_before
            || connection.phase != phase_before {
            connection.active_ms = now;
        }
    }
}

fn input_pending(connection: Connection&) -> bool {
    return (connection.phase == ConnectionPhase.Reading || connection.phase == ConnectionPhase.ReadingBody)
        && connection.staged_read < connection.staged_bytes;
}

fn server_poll_timeout(storage: ServerStorage, options: ServerOptions) -> i32 {
    for &connection in storage.connections {
        if input_pending(connection) {
            return 0;
        }
    }
    return options.poll_timeout_ms;
}

fn connection_buffers(storage: ServerStorage, options: ServerOptions, index: i64) -> ConnectionBuffers {
    let input_start = index * options.limits.head_bytes_max;
    let head_start = index * options.response_head_bytes_max;
    let body_start = index * options.limits.output_bytes_max;
    let request_start = index * options.limits.body_bytes_max;
    let staging_start = index * server_read_bytes(options);
    return ConnectionBuffers {
        input: storage.input[input_start..input_start + options.limits.head_bytes_max],
        head: storage.head[head_start..head_start + options.response_head_bytes_max],
        body: storage.body[body_start..body_start + options.limits.output_bytes_max],
        request: storage.request[request_start..request_start + options.limits.body_bytes_max],
        staging: storage.staging[staging_start..staging_start + server_read_bytes(options)],
        hooks: storage.hooks,
    };
}
