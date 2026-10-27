// One thread owns its accepted sockets, request state and nonmoving response slabs.
namespace silly;

import std;

import.connection;
import.lifecycle_types;
import.server;
import.server_loop;
import.server_observer;
import.server_options;
import.transport;
import.worker_executor;
import.worker_message;

// Consumes wake. The supervisor owns the sole producer and reclaims queued fds after join.
fn run_worker_state<Tag, D, E, H, O>(options: ServerOptions,
    wake: silly_transport::Descriptor, driver: D&) -> ServerResult {
    var owned_wake = wake;
    if !valid_server_options(options) || wake.fd < 0 {
        silly_transport::close(owned_wake);
        return ServerResult {
            ok: false,
            error: ServerError.InvalidOptions,
            message: "invalid worker options",
            ..
        };
    }
    var hooks = HookState {
    };
    observe_server(driver, hooks, ServerEvent.Start, O);
    if hooks.failure != HookResult.Ok {
        observe_server(driver, hooks, ServerEvent.Stop, O);
        silly_transport::close(owned_wake);
        return hook_server_result(hooks);
    }
    fn drive_loop(storage: ServerStorage&, settings: ServerOptions, unused: silly_transport::Descriptor,
        control: silly_transport::Descriptor, state: D&) -> ServerResult {
        return worker_loop<Tag>(storage, settings, control, state, E, H, O);
    }
    return run_server_storage_loop(options, silly_transport::Descriptor {
        }, owned_wake, driver, hooks, E, H, O, drive_loop);
}

fn worker_loop<Tag, D, E, H, O>(storage: ServerStorage&, options: ServerOptions,
    wake: silly_transport::Descriptor, driver: D&) -> ServerResult {
    while true {
        if storage.hooks.failure != HookResult.Ok {
            return hook_server_result(storage.hooks);
        }
        let stop, stopping = qpoll<WorkerStop<Tag>>();
        if stopping {
            return ServerResult {
                ok: true,
                ..
            };
        }
        // Drain notification before mailbox. A producer racing this drain cannot lose its message.
        let notification = silly_transport::drain_wake(wake);
        if notification.status == silly_transport::IoStatus.Closed {
            return ServerResult {
                ok: true,
                ..
            };
        }
        if notification.status != silly_transport::IoStatus.Ready
            && notification.status != silly_transport::IoStatus.WouldBlock
            && notification.status != silly_transport::IoStatus.Interrupted {
            return worker_io_failure(ServerError.Wake, notification);
        }
        let clock = silly_transport::monotonic_ms();
        if clock.status != silly_transport::IoStatus.Ready {
            return worker_io_failure(ServerError.Clock, clock);
        }
        let completed = drain_executor_results<Tag>(storage, options, driver, clock.count, E);
        let exhausted = drain_worker_accepts<Tag>(storage.connections, options.accepts_per_turn, clock.count);
        prepare_poll(storage, silly_transport::Descriptor {
            }, wake);
        let timeout = if exhausted || completed {
            0
        } else {
            server_poll_deadline(storage, options, clock.count)
        };
        let ready = silly_transport::poll(storage.fds, storage.interests, storage.events, timeout);
        if ready.status == silly_transport::IoStatus.Interrupted {
            continue;
        }
        if ready.status != silly_transport::IoStatus.Ready {
            return worker_io_failure(ServerError.Poll, ready);
        }
        let now = silly_transport::monotonic_ms();
        if now.status != silly_transport::IoStatus.Ready {
            return worker_io_failure(ServerError.Clock, now);
        }
        service_connections(storage, options, now.count, driver, H, E, O);
    }
    return ServerResult {
        ok: true,
        ..
    };
}

// Refusal closes immediately; no descriptor can accumulate outside the mailbox or fixed slots.
// True means the drain budget ran out, so the next poll must not sleep.
fn drain_worker_accepts<Tag>(connections: Connection[:], budget: i64, now: i64) -> bool {
    for attempt in budget {
        let message, present = qpoll<AcceptMessage<Tag>>();
        if !present {
            return false;
        }
        var socket = silly_transport::Descriptor {
            fd: message.fd
        };
        let index = available_connection(connections);
        if index < 0 {
            silly_transport::close(socket);
            continue;
        }
        let generation = connections[index].generation + 1;
        connections[index] = Connection {
            socket: socket,
            generation: generation,
            phase: ConnectionPhase.Reading,
            active_ms: now,
            ..
        };
    }
    return true;
}

fn worker_io_failure(error: ServerError, io: silly_transport::IoResult) -> ServerResult {
    return ServerResult {
        ok: false,
        error: error,
        message: "worker transport failed",
        system_error: io.error,
        ..
    };
}
