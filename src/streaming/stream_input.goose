// Input is decoded only on demand into one callback-local fixed scratch chunk.
namespace silly;

import std;

import.continuation;
import.stream;
import.stream_contract;
import.stream_driver;

fn stream_wants_input<S>(slot: StreamSlot<S>&) -> bool {
    return slot.input_enabled && !slot.input_failed
        && (slot.producer.continuation.phase == ContinuationPhase.Waiting
        || (slot.producer.duplex && slot.producer.continuation.phase == ContinuationPhase.Pending))
        && input_wake(slot.producer.continuation.wake);
}

fn stream_input_ready<S>(slot: StreamSlot<S>&, connection: Connection&) -> bool {
    return stream_wants_input(slot) && (connection.staged_read < connection.staged_bytes
        || body_terminal(connection.reader.status) || slot.input_eof || slot.input_ended);
}

// InputFailed is observable once, but cannot turn malformed input into successful framing.
fn fail_stream_input<S, F>(slot: StreamSlot<S>&, connection: Connection&, now: i64) {
    if slot.input_failed {
        return;
    }
    let wanted = stream_wants_input(slot);
    slot.input_failed = true;
    connection.close_after_reply = true;
    let producer .= slot.producer;
    if wanted {
        stream_resume(producer, producer.continuation.key, StreamEvent.InputFailed {
                reason: StreamError.Input,
            }, now, F);
        slot.input_stepped = true;
    }
    if !terminal(producer.continuation) {
        stream_fail(producer, producer.continuation.key, StreamError.Input, F);
    } else {
        stream_failure_policy(producer);
    }
}

fn read_stream_input<S, F>(slot: StreamSlot<S>&, connection: Connection&,
    buffers: ConnectionBuffers, options: ServerOptions, now: i64, events: i32) {
    if !stream_wants_input(slot) {
        return;
    }
    if slot.input_ended {
        stream_fail(slot.producer, slot.producer.continuation.key, StreamError.InvalidStep, F);
        return;
    }
    if connection.reader.status == BodyStatus.Complete {
        slot.input_ended = true;
        slot.input_stepped = true;
        stream_resume(slot.producer, slot.producer.continuation.key, StreamEvent.InputEnd, now, F);
        return;
    }
    if connection.staged_read == connection.staged_bytes && !slot.input_eof {
        if (events & (silly_transport::READ | silly_transport::CLOSED)) == 0 {
            return;
        }
        let read = silly_transport::read(connection.socket, buffers.staging);
        if read.status == silly_transport::IoStatus.Ready {
            connection.staged_read = 0;
            connection.staged_bytes = read.count;
            connection.received_bytes += read.count;
            if read.count > 0 {
                connection.active_ms = now;
            }
        } else if read.status == silly_transport::IoStatus.Closed {
            slot.input_eof = true;
            connection.close_after_reply = true;
        } else if read.status != silly_transport::IoStatus.WouldBlock
            && read.status != silly_transport::IoStatus.Interrupted {
            connection.completion.system_error = read.error;
            slot.input_eof = true;
        }
    }
    decode_stream_input(slot, connection, buffers, options, now, F);
}

fn decode_stream_input<S, F>(slot: StreamSlot<S>&, connection: Connection&,
    buffers: ConnectionBuffers, options: ServerOptions, now: i64) {
    var decoded: u8[4096] = [0; 4096];
    let capacity = min(decoded.len, slot.producer.limits.pending_bytes_max);
    let result = read_body(connection.reader,
        buffers.staging[connection.staged_read..connection.staged_bytes],
        decoded[..capacity], options.work_bytes_per_turn);
    connection.staged_read += result.consumed;
    if body_terminal(result.status) && result.status != BodyStatus.Complete {
        fail_stream_input(slot, connection, now, F);
        return;
    }
    if result.produced > 0 {
        slot.input_stepped = true;
        stream_resume(slot.producer, slot.producer.continuation.key, StreamEvent.Input {
                bytes: decoded[..result.produced],
            }, now, F);
    } else if slot.input_eof && connection.staged_read == connection.staged_bytes
        && connection.reader.status != BodyStatus.Complete {
        finish_body(connection.reader);
        fail_stream_input(slot, connection, now, F);
    } else if connection.reader.status == BodyStatus.Complete {
        slot.input_ended = true;
        slot.input_stepped = true;
        stream_resume(slot.producer, slot.producer.continuation.key, StreamEvent.InputEnd, now, F);
    }
}
