// Header serialization precedes commitment. The scheduler decides when wire output starts.
namespace silly;

import std;

import.body_types;
import.connection;
import.continuation;
import.http_writer;
import.lifecycle_driver;
import.response;
import.response_wire_types;
import.route_driver;
import.route_types;
import.server_body;
import.server_buffers;
import.state;
import.stream;
import.stream_driver;
import.stream_metadata;
import.transfer_key;

fn stage_application_reply(driver: NoState&, connection: Connection&, buffers: ConnectionBuffers,
    response: Response&, wire_options: ResponseWireOptions, cap: i64) -> ResponseError {
    return stage_reply(connection, buffers, response, wire_options, cap);
}

fn stage_application_reply<R>(driver: RoutePlan<R>&, connection: Connection&, buffers: ConnectionBuffers,
    response: Response&, wire_options: ResponseWireOptions, cap: i64) -> ResponseError {
    return stage_reply(connection, buffers, response, wire_options, cap);
}

fn stage_application_reply<R, A>(driver: RouteDriver<R, A> & , connection: Connection&, buffers: ConnectionBuffers,
    response: Response&, wire_options: ResponseWireOptions, cap: i64) -> ResponseError {
    return stage_reply(connection, buffers, response, wire_options, cap);
}

fn stage_application_reply<R, A>(driver: LifecycleDriver<R, A> & , connection: Connection&, buffers: ConnectionBuffers,
    response: Response&, wire_options: ResponseWireOptions, cap: i64) -> ResponseError {
    return stage_reply(connection, buffers, response, wire_options, cap);
}

fn stage_application_reply<R, A, S>(driver: StreamDriver<R, A, S> & , connection: Connection&,
    buffers: ConnectionBuffers, response: Response&, wire_options: ResponseWireOptions, cap: i64) -> ResponseError {
    let slot .= driver.slots[driver.current];
    if response.mode == ResponseBodyMode.Stream && !slot.start.selected {
        return ResponseError.InvalidState;
    }
    if response.mode != ResponseBodyMode.Stream {
        var buffered_wire = wire_options;
        if connection.streamed_input && connection.reader.status != BodyStatus.Complete {
            buffered_wire.close = true;
        }
        return stage_reply(connection, buffers, response, buffered_wire, cap);
    }
    var wire: u8[>..] = [];
    var stream_wire = wire_options;
    if connection.streamed_input && connection.reader.status != BodyStatus.Complete
        && (!slot.start.input || wire_options.request_method == "HEAD" || response.status == 204
        || response.status == 205 || response.status == 304) {
        stream_wire.close = true;
    }
    var plan = ResponseWirePlan {
        close: stream_wire.close,
        ..
    };
    slot.deferred = slot.start.defer_headers;
    if slot.deferred {
        plan.error = retain_stream_head(slot, response, stream_wire, min(cap, buffers.head.len));
    } else {
        plan = prepare_response_head(wire, response, stream_wire, min(cap, buffers.head.len));
    }
    if plan.error != ResponseError.None {
        return plan.error;
    }
    copy_server_bytes(buffers.head, wire);
    initialize_stream_slot(slot, connection);
    slot.framing = plan.framing;
    slot.fixed_remaining = if plan.framing == ResponseFraming.Fixed {
        plan.body_bytes
    } else {
        -1
    };
    connection.close_after_reply = plan.close;
    connection.head_bytes = wire.len;
    connection.body_bytes = 0;
    connection.head_sent = 0;
    connection.body_sent = 0;
    connection.phase = ConnectionPhase.Writing;
    return ResponseError.None;
}

fn initialize_stream_slot<S>(slot: StreamSlot<S>&, connection: Connection&) {
    slot.producer = StreamProducer<S> {
        continuation: Continuation<S> {
            key: TransferKey {
                owner: 0,
                slot: connection.slot,
                connection_generation: connection.generation,
                request_generation: connection.request_generation,
            },
            state: slot.start.state,
            ..
        },
        limits: StreamLimits {
            pending_bytes_max: slot.start.pending_bytes_max
        },
        duplex: slot.start.duplex,
        ..
    };
    slot.input_enabled = slot.start.input;
    slot.input_ended = false;
    slot.input_failed = false;
    slot.input_eof = false;
    slot.input_started_ms = -1;
    slot.start.selected = false;
    slot.active = true;
    slot.cursor = WireCursor {
    };
    slot.prefix.clear();
    slot.chunk_started = false;
    slot.ending = false;

}

fn driver_streaming(driver: NoState&) -> bool {
    return false;
}

fn driver_streaming<R>(driver: RoutePlan<R>&) -> bool {
    return false;
}

fn driver_streaming<R, A>(driver: RouteDriver<R, A> & ) -> bool {
    return false;
}

fn driver_streaming<R, A>(driver: LifecycleDriver<R, A> & ) -> bool {
    return false;
}

fn driver_streaming<R, A, S>(driver: StreamDriver<R, A, S> & ) -> bool {
    return true;
}
