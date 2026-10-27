// Timer/input waiting uses idle activity; only offered output uses write inactivity.
namespace silly;

import.connection;
import.connection_deadlines;
import.server_options;
import.stream;
import.stream_driver;
import.timeout_types;

fn stream_wants_write<S>(slot: StreamSlot<S>&, connection: Connection&) -> bool {
    return slot.producer.commit_requested && (connection.head_sent < connection.head_bytes
        || stream_pending_bytes(slot.producer) > 0 || slot.ending);
}

fn stream_deadline<S>(slot: StreamSlot<S>&, connection: Connection&,
    options: ServerOptions, now: i64) -> i64 {
    let budget = if stream_wants_write(slot, connection) {
        options.write_timeout_ms
    } else {
        options.idle_timeout_ms
    };
    return timeout_remaining(now, connection.active_ms, budget);
}

fn stream_timeout<S>(slot: StreamSlot<S>&, connection: Connection&,
    options: ServerOptions, now: i64) -> TimeoutKind {
    if stream_deadline(slot, connection, options, now) > 0 {
        return TimeoutKind.None;
    }
    return if stream_wants_write(slot, connection) {
        TimeoutKind.Write
    } else {
        TimeoutKind.Idle
    };
}
