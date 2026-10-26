// Poll-driven single-owner loop over fixed descriptors and bounded, nonmoving byte slabs.
namespace silly;

import std;

import.connection;
import.server_io;
import.server_options;
import.transport;

struct ServerStorage {
    connections: Connection[:],
    input: u8[:],
    head: u8[:],
    body: u8[:],
    fds: i32[:],
    interests: i32[:],
    events: i32[:],
}

fn server_loop<H>(storage: ServerStorage&, options: ServerOptions,
    listener: silly_transport::Descriptor, wake: silly_transport::Descriptor) -> ServerResult {
    var running = true;
    while running {
        prepare_poll(storage, listener, wake);
        let ready = silly_transport::poll(storage.fds, storage.interests, storage.events, options.poll_timeout_ms);
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
        service_connections(storage, options, clock.count, H);
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
        let connection = storage.connections[index];
        storage.fds[index + 2] = connection.socket.fd;
        storage.interests[index + 2] = match connection.phase {
            Free => {
                0
            },
            Reading => {
                silly_transport::READ
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

fn service_connections<H>(storage: ServerStorage&, options: ServerOptions, now: i64) {
    for index in storage.connections.len {
        let connection .= storage.connections[index];
        if connection.phase == ConnectionPhase.Free {
            continue;
        }
        if now < connection.active_ms || now - connection.active_ms >= options.idle_timeout_ms {
            release_connection(connection);
            continue;
        }
        let events = storage.events[index + 2];
        if events == 0 {
            continue;
        }
        let head_start = index * options.response_head_bytes_max;
        let body_start = index * options.limits.output_bytes_max;
        let head = storage.head[head_start..head_start + options.response_head_bytes_max];
        let body = storage.body[body_start..body_start + options.limits.output_bytes_max];
        let input_before = connection.input_bytes;
        let output_before = connection.head_sent + connection.body_sent;
        if connection.phase == ConnectionPhase.Reading {
            let start = index * options.limits.head_bytes_max;
            let input = storage.input[start..start + options.limits.head_bytes_max];
            read_connection(connection, input, head, body, options, H);
        } else {
            write_connection(connection, head, body, options.work_bytes_per_turn);
        }
        if connection.input_bytes != input_before || connection.head_sent + connection.body_sent != output_before {
            connection.active_ms = now;
        }
    }
}
