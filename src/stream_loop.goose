// One bounded producer/I/O turn per slot; readiness and monotonic timers share the poll loop.
namespace silly;

import std;

import.body_types;
import.connection;
import.connection_deadlines;
import.continuation;
import.lifecycle_types;
import.response_errors;
import.response_wire_types;
import.server_executor;
import.server_loop;
import.server_observer;
import.server_options;
import.stream;
import.stream_deadlines;
import.stream_driver;
import.stream_input;
import.stream_transport;
import.timeout_types;
import.transport;
import.wire_transfer;

fn stream_poll<R, A, S>(storage: ServerStorage&, options: ServerOptions,
    driver: StreamDriver<R, A, S> & , now: i64) -> i32 {
    var timeout: i64 = if storage.service_pending {
        0
    } else {
        options.poll_timeout_ms
    };
    for index in driver.slots.len {
        let slot .= driver.slots[index];
        let connection .= storage.connections[index];
        if !slot.active {
            timeout = min(timeout, connection_wait_ms(connection, options, now));
            if input_pending(connection) {
                timeout = 0;
            }
            continue;
        }
        timeout = min(timeout, stream_deadline(slot, connection, options, now));
        storage.interests[index + 2] = if stream_wants_write(slot, connection) {
            silly_transport::WRITE
        } else {
            0
        };
        if slot.input_enabled {
            if stream_wants_input(slot) && connection.staged_read == connection.staged_bytes
                && !slot.input_eof && !body_terminal(connection.reader.status) {
                storage.interests[index + 2] |= silly_transport::READ;
            }
            if stream_input_ready(slot, connection) {
                timeout = 0;
            }
            // No read-ahead while the producer waits elsewhere. The timer/idle deadline remains active;
            // its next demand restores this descriptor, avoiding repeated HUP with no useful I/O.
            if storage.interests[index + 2] == 0 {
                storage.fds[index + 2] = -1;
            }
        } else if connection.staged_bytes - connection.staged_read < server_read_bytes(options) {
            storage.interests[index + 2] |= silly_transport::READ;
        }
        timeout = min(timeout, stream_wait_ms(slot.producer, now));
        if terminal(slot.producer.continuation) && connection.head_sent == connection.head_bytes
            && (!slot.ending || slot.cursor.status == WireStatus.Complete) {
            timeout = 0;
        }
    }
    return timeout as i32;
}

fn stream_server_loop<R, A, S, H, F, O>(storage: ServerStorage&, options: ServerOptions,
    listener: silly_transport::Descriptor, wake: silly_transport::Descriptor,
    driver: StreamDriver<R, A, S> & ) -> ServerResult {
    while true {
        if storage.hooks.failure != HookResult.Ok {
            return hook_server_result(storage.hooks);
        }
        let before = silly_transport::monotonic_ms();
        if before.status != silly_transport::IoStatus.Ready {
            return ServerResult {
                ok: false,
                error: ServerError.Clock,
                message: "clock failed",
                ..
            };
        }
        prepare_poll(storage, listener, wake);
        let timeout = stream_poll(storage, options, driver, before.count);
        let result = silly_transport::poll(storage.fds, storage.interests, storage.events, timeout);
        if result.status == silly_transport::IoStatus.Interrupted {
            continue;
        }
        if result.status != silly_transport::IoStatus.Ready {
            return ServerResult {
                ok: false,
                error: ServerError.Poll,
                message: "poll failed",
                ..
            };
        }
        if storage.events[1] != 0 {
            return ServerResult {
                ok: true,
                ..
            };
        }
        let clock = silly_transport::monotonic_ms();
        if clock.status != silly_transport::IoStatus.Ready {
            return ServerResult {
                ok: false,
                error: ServerError.Clock,
                message: "clock failed",
                ..
            };
        }
        let accepted = stream_accept_ready(storage, options, listener, clock.count);
        if !accepted.ok {
            return accepted;
        }
        service_stream_slots(storage, options, driver, clock.count, H, F, O);
    }
    return ServerResult {
        ok: true,
        ..
    };
}

fn service_stream_slots<R, A, S, H, F, O>(storage: ServerStorage&, options: ServerOptions,
    driver: StreamDriver<R, A, S> & , now: i64) {
    let start = storage.service_cursor;
    var serviced = 0;
    storage.service_pending = false;
    for offset in storage.connections.len {
        if storage.hooks.failure != HookResult.Ok {
            return;
        }
        let index = (start + offset) % storage.connections.len;
        let connection .= storage.connections[index];
        if connection.phase == ConnectionPhase.Free {
            continue;
        }
        driver.current = index;
        let slot .= driver.slots[index];
        let events = storage.events[index + 2];
        if !slot.active && events == 0 && !input_pending(connection)
            && !connection_expired(connection, options, now) {
            continue;
        }
        if slot.active && events == 0 && !stream_input_ready(slot, connection)
            && stream_wait_ms(slot.producer, now) > 0
            && !terminal(slot.producer.continuation)
            && stream_timeout(slot, connection, options, now) == TimeoutKind.None {
            continue;
        }
        if serviced >= options.dispatches_per_turn {
            storage.service_pending = true;
            return;
        }
        if slot.active {
            service_active_stream(storage, options, driver, now, F, O);
        } else {
            service_connection(storage, options, now, driver, index, H, default_response_error, O);
            if slot.start.selected {
                cancel_stream_slot(slot, F);
            }
        }
        serviced += 1;
        storage.service_cursor = (index + 1) % storage.connections.len;
    }
}

fn service_active_stream<R, A, S, F, O>(storage: ServerStorage&, options: ServerOptions,
    driver: StreamDriver<R, A, S> & , now: i64) {
    let index = driver.current;
    let connection .= storage.connections[index];
    let buffers = connection_buffers(storage, options, index);
    let events = storage.events[index + 2];
    let slot .= driver.slots[index];
    slot.input_stepped = false;
    if slot.input_enabled {
        if slot.input_started_ms < 0 {
            slot.input_started_ms = now;
        }
        let was_writable = stream_wants_write(slot, connection);
        if stream_timeout(slot, connection, options, now) == TimeoutKind.None
            && (slot.framing == ResponseFraming.Chunked || slot.framing == ResponseFraming.Close) {
            read_stream_input(slot, connection, buffers, options, now, events, F);
        }
        if !was_writable && stream_wants_write(slot, connection) {
            connection.active_ms = now;
        }
    } else {
        read_executing(connection, buffers.staging, events, options.work_bytes_per_turn);
    }
    if connection.phase == ConnectionPhase.Free {
        finish_stream_connection(driver, connection, storage.hooks, TransferOutcome.Cancelled, F, O);
        return;
    }
    var serviced_events = events;
    if slot.input_enabled {
        // A FIN may follow valid staged bytes. Let the decoder resolve EOF before cancellation.
        serviced_events &= ~silly_transport::CLOSED;
        if (events & silly_transport::CLOSED) != 0 && stream_wants_write(slot, connection) {
            serviced_events |= silly_transport::WRITE;
        }
    }
    service_stream(driver, connection, buffers, options, now, serviced_events, F, O);
}

fn stream_accept_ready(storage: ServerStorage&, options: ServerOptions,
    listener: silly_transport::Descriptor, now: i64) -> ServerResult {
    if (storage.events[0] & (silly_transport::ERROR | silly_transport::CLOSED)) != 0 {
        return ServerResult {
            ok: false,
            error: ServerError.Listen,
            message: "listener failed",
            ..
        };
    }
    if (storage.events[0] & silly_transport::READ) != 0 {
        let accepted = accept_connections(storage.connections, listener, options, now);
        if accepted.status != silly_transport::IoStatus.Ready
            && accepted.status != silly_transport::IoStatus.WouldBlock
            && accepted.status != silly_transport::IoStatus.Interrupted {
            return ServerResult {
                ok: false,
                error: ServerError.Accept,
                message: "accept failed",
                ..
            };
        }
    }
    return ServerResult {
        ok: true,
        ..
    };
}
