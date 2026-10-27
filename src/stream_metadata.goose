// Deferred heads own typed fields until producer metadata is available.
namespace silly;

import std;

import.body_types;
import.connection;
import.headers;
import.http_writer;
import.response;
import.response_wire_types;
import.server_buffers;
import.stream_driver;

fn retain_stream_head<S>(slot: StreamSlot<S>&, response: Response&,
    options: ResponseWireOptions, cap: i64) -> ResponseError {
    if response.phase != ResponsePhase.Prepared || response.output.len != 0
        || options.request_method.len > slot.request_method.cap {
        return ResponseError.InvalidState;
    }
    if response.header_fields.len > slot.retained_fields.cap {
        return ResponseError.HeaderCountLimit;
    }
    if response.header_bytes.len > slot.retained_headers.cap {
        return ResponseError.HeaderBytesLimit;
    }
    slot.retained_fields.clear();
    slot.retained_headers.clear();
    slot.request_method.clear();
    slot.retained_fields.append(response.header_fields);
    slot.retained_headers.append(response.header_bytes);
    slot.request_method.append(options.request_method);
    slot.retained_limits = response.limits;
    slot.retained_cap = cap;
    return ResponseError.None;
}

fn finalize_stream_head<S>(slot: StreamSlot<S>&, connection: Connection&,
    buffers: ConnectionBuffers) -> ResponseError {
    let metadata = slot.producer.continuation.metadata;
    var fields: HeaderField[>..] = [];
    var bytes: u8[>..] = [];
    var output: u8[>..] = [];
    fields.append(slot.retained_fields);
    bytes.append(slot.retained_headers);
    var response = Response {
        limits: slot.retained_limits,
        header_fields: fields,
        header_bytes: bytes,
        output: output,
        phase: ResponsePhase.Prepared,
        mode: ResponseBodyMode.Stream,
        status: metadata.status,
        ..
    };
    if metadata.etag.len > 0 && add_header(response, "ETag", metadata.etag) != ResponseError.None {
        return response.error;
    }
    if metadata.last_modified.len > 0
        && add_header(response, "Last-Modified", metadata.last_modified) != ResponseError.None {
        return response.error;
    }
    var options = ResponseWireOptions {
        http_minor: connection.http_minor,
        request_method: slot.request_method,
        close: connection.close_after_reply,
        stream_length: metadata.representation_length,
        ..
    };
    if connection.streamed_input && connection.reader.status != BodyStatus.Complete
        && (metadata.status == 204 || metadata.status == 205 || metadata.status == 304) {
        options.close = true;
    }
    if slot.request_method == "HEAD" || metadata.status == 304 {
        options.representation_length = metadata.representation_length;
    }
    var wire: u8[>..] = [];
    let plan = prepare_response_head(wire, response, options, slot.retained_cap);
    if plan.error != ResponseError.None {
        return plan.error;
    }
    copy_server_bytes(buffers.head, wire);
    connection.head_bytes = wire.len;
    connection.completion.status = metadata.status;
    connection.close_after_reply = plan.close;
    slot.framing = plan.framing;
    slot.fixed_remaining = if plan.framing == ResponseFraming.Fixed {
        plan.body_bytes
    } else {
        -1
    };
    slot.deferred = false;
    return ResponseError.None;
}
