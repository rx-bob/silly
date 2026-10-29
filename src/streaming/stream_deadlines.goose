// Timer/input waiting uses idle activity; only offered output uses write inactivity.
namespace silly;

import std;

import.stream;
import.stream_driver;

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
    let activity = timeout_remaining(now, connection.active_ms, budget);
    if slot.input_enabled && slot.input_started_ms >= 0 && connection.reader.status != BodyStatus.Complete {
        return min(activity, timeout_remaining(now, slot.input_started_ms, options.body_timeout_ms));
    }
    return activity;
}

fn stream_timeout<S>(slot: StreamSlot<S>&, connection: Connection&,
    options: ServerOptions, now: i64) -> TimeoutKind {
    if slot.input_enabled && slot.input_started_ms >= 0 && connection.reader.status != BodyStatus.Complete
        && timeout_elapsed(now, slot.input_started_ms, options.body_timeout_ms) {
        return TimeoutKind.Body;
    }
    if stream_deadline(slot, connection, options, now) > 0 {
        return TimeoutKind.None;
    }
    return if stream_wants_write(slot, connection) {
        TimeoutKind.Write
    } else {
        TimeoutKind.Idle
    };
}
