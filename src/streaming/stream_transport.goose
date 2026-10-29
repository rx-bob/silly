// Streaming keeps headers, chunk framing and owned producer bytes in separate fixed storage.
namespace silly;

import std;

import.continuation;
import.stream;
import.stream_contract;
import.stream_deadlines;
import.stream_driver;
import.stream_failure;
import.stream_input;
import.stream_metadata;

fn cancel_stream_slot<S, F>(slot: StreamSlot<S>&) {
    if slot.active {
        stream_cancel(slot.producer, slot.producer.continuation.key, F);
        slot.active = false;
    }
    if slot.start.selected {
        var pending = Continuation<S> {
            key: TransferKey {
                owner: 0,
                slot: 0,
                connection_generation: 1,
                request_generation: 1
            },
            state: slot.start.state,
            ..
        };
        slot.start.selected = false;
        cancel_continuation(pending, pending.key, F);
    }
}

fn finish_stream_connection<R, A, S, F, O>(driver: StreamDriver<R, A, S> & ,
    connection: Connection&, hooks: HookState&, outcome: TransferOutcome) {
    if connection.streamed_input && connection.reader.status != BodyStatus.Complete {
        connection.close_after_reply = true;
    }
    cancel_stream_slot(driver.slots[driver.current], F);
    finish_transfer(connection, driver, hooks, outcome, O);
    if outcome != TransferOutcome.Delivered || connection.close_after_reply || connection.draining {
        release_connection(connection);
    } else {
        reset_connection(connection);
    }
}

fn stream_socket_write<S>(slot: StreamSlot<S>&, connection: Connection&,
    head: u8[:], budget: i64) -> WireWrite {
    if connection.head_sent < connection.head_bytes {
        var cursor = WireCursor {
            prefix_sent: connection.head_sent,
            ..
        };
        stream_commit(slot.producer, slot.producer.continuation.key);
        let result = write_wire(connection.socket, cursor, WireParts {
                prefix: head[..connection.head_bytes],
                ..
            }, budget);
        connection.head_sent = cursor.prefix_sent;

        return result;
    }
    let state .= slot.producer.continuation;
    if slot.ending {
        return write_wire(connection.socket, slot.cursor, WireParts {
                prefix: "0\r\n\r\n",
                ..
            }, budget);
    }
    if stream_pending_bytes(slot.producer) == 0 {
        return WireWrite {
            status: WireStatus.Blocked,
            ..
        };
    }
    if !slot.chunk_started {
        slot.prefix.clear();
        if slot.framing == ResponseFraming.Chunked {
            var prefix: u8[>..] = [];
            write_chunk_prefix(prefix, state.produced, slot.prefix.cap);
            slot.prefix.append(prefix);
        }
        slot.cursor = WireCursor {
        };
        slot.chunk_started = true;
    }
    let result = write_wire(connection.socket, slot.cursor, WireParts {
            prefix: slot.prefix,
            payload: state.chunk[..state.produced],
            suffix: if slot.framing == ResponseFraming.Chunked {
                "\r\n"
            } else {
                ""
            },
        }, budget);
    // Retain payload until its framing suffix has drained too.
    if result.status == WireStatus.Complete {
        if slot.framing == ResponseFraming.Fixed {
            slot.fixed_remaining -= state.produced;
        }
        stream_acknowledge(slot.producer, state.key, state.produced);
        slot.chunk_started = false;
    }
    return result;
}

fn service_stream<R, A, S, F, O>(driver: StreamDriver<R, A, S> & , connection: Connection&,
    buffers: ConnectionBuffers, options: ServerOptions, now: i64, events: i32) {
    let slot .= driver.slots[driver.current];
    let producer .= slot.producer;
    let expired = stream_timeout(slot, connection, options, now);
    if expired != TimeoutKind.None {
        connection.completion.timeout = expired;
        if slot.input_enabled && !slot.input_ended && !producer.committed {
            fail_stream_input(slot, connection, now, F);
        } else {
            finish_stream_connection(driver, connection, buffers.hooks, TransferOutcome.Cancelled, F, O);
            return;
        }
    }
    if (events & (silly_transport::CLOSED | silly_transport::ERROR)) != 0 {
        finish_stream_connection(driver, connection, buffers.hooks, TransferOutcome.Cancelled, F, O);
        return;
    }
    let was_writable = stream_wants_write(slot, connection);
    advance_stream_output(slot, connection, buffers, now, F);
    if producer.render_error {
        cancel_stream_slot(slot, F);
        render_stream_failure(connection, buffers, options, producer.continuation.failure);
        connection.active_ms = now;
        return;
    }
    if producer.close_required {
        finish_stream_connection(driver, connection, buffers.hooks, TransferOutcome.Cancelled, F, O);
        return;
    }
    if terminal(producer.continuation) && stream_pending_bytes(producer) == 0 {
        producer.commit_requested = true;
        if connection.head_sent == connection.head_bytes {
            if slot.framing != ResponseFraming.Chunked || slot.ending {
                if !slot.ending || slot.cursor.status == WireStatus.Complete {
                    finish_stream_connection(driver, connection, buffers.hooks, TransferOutcome.Delivered, F, O);
                    return;
                }
            } else {
                slot.ending = true;
                slot.cursor = WireCursor {
                };
            }
        }
    }
    if !was_writable && stream_wants_write(slot, connection) {
        connection.active_ms = now;
    }
    if !producer.commit_requested || (events & silly_transport::WRITE) == 0 {
        return;
    }
    let result = stream_socket_write(slot, connection, buffers.head, options.work_bytes_per_turn);
    connection.completion.wire_bytes += result.count;
    if result.count > 0 {
        connection.active_ms = now;
    }
    if result.status == WireStatus.Failed || result.status == WireStatus.InvalidState {
        connection.completion.system_error = result.system_error;
        finish_stream_connection(driver, connection, buffers.hooks, TransferOutcome.Cancelled, F, O);
    }
}

fn advance_stream_output<S, F>(slot: StreamSlot<S>&, connection: Connection&,
    buffers: ConnectionBuffers, now: i64) {
    advance_stream_producer(slot, now, F);
    let producer .= slot.producer;
    if producer.render_error || producer.close_required {
        return;
    }
    if slot.deferred {
        if stream_pending_bytes(producer) != 0 || terminal(producer.continuation) {
            stream_failure_policy(producer);
            return;
        }
        if !producer.continuation.metadata.ready {
            return;
        }
        if finalize_stream_head(slot, connection, buffers) != ResponseError.None {
            stream_failure_policy(producer);
            return;
        }
        // Metadata publication precedes any file read, including HEAD/304 cancellation.
        if slot.framing == ResponseFraming.None || slot.fixed_remaining == 0 {
            advance_stream_producer(slot, now, F);
        }
    }
    if slot.framing == ResponseFraming.Fixed && (stream_pending_bytes(producer) > slot.fixed_remaining
        || (terminal(producer.continuation) && slot.fixed_remaining > 0)) {
        stream_failure_policy(producer);
    }
}

fn advance_stream_producer<S, F>(slot: StreamSlot<S>&, now: i64) {
    let producer .= slot.producer;
    if !slot.deferred && (slot.framing == ResponseFraming.None
        || (slot.framing == ResponseFraming.Fixed && slot.fixed_remaining == 0)) {
        stream_cancel(producer, producer.continuation.key, F);
        producer.close_required = false;
        producer.commit_requested = true;
    } else if !slot.input_stepped && !slot.ending
        && (stream_pending_bytes(producer) == 0 || producer.duplex)
        && !terminal(producer.continuation) {
        stream_resume(producer, producer.continuation.key, StreamEvent.Ready, now, F);
    }
}

fn render_stream_failure(connection: Connection&, buffers: ConnectionBuffers,
    options: ServerOptions, selected: StreamFailureResponse&) {
    if selected.selected {
        render_owned_stream_failure(selected, connection, buffers, options);
        return;
    }
    var failure = ResponseFailure {
        kind: ResponseFailureKind.HandlerFailure,
        error: ResponseError.Application,
        ..
    };
    if connection.completion.timeout != TimeoutKind.None {
        failure.kind = ResponseFailureKind.Timeout;
        failure.status = 408;
        failure.timeout = connection.completion.timeout;
    } else if connection.streamed_input && body_terminal(connection.reader.status)
        && connection.reader.status != BodyStatus.Complete {
        failure.kind = ResponseFailureKind.RequestBody;
        failure.status = body_status_code(connection.reader.status);
        failure.body_error = connection.reader.status;
    }
    render_reply(connection, buffers, options, ResponseWireOptions {
            http_minor: connection.http_minor,
            request_method: connection.completion.method,
            close: true,
            ..
        }, failure, default_response_error);
}
