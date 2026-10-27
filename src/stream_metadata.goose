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
    let error = restore_stream_headers(slot, response);
    if error != ResponseError.None {
        return error;
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

fn restore_stream_headers<S>(slot: StreamSlot<S>&, response: Response&) -> ResponseError {
    let metadata = slot.producer.continuation.metadata;
    for index in slot.retained_fields.len {
        if !valid_response_offsets(slot.retained_fields[index], slot.retained_headers.len) {
            return ResponseError.InvalidHeader;
        }
        let field = header_view(slot.retained_fields, slot.retained_headers, index);
        if (metadata.content_type.len > 0 && header_name_equal(field.name, "Content-Type"))
            || ((metadata.content_range.len > 0 || metadata.suppress_content_range)
            && header_name_equal(field.name, "Content-Range"))
            || ((metadata.content_encoding.len > 0 || metadata.suppress_content_encoding)
            && header_name_equal(field.name, "Content-Encoding"))
            || (metadata.location.len > 0 && header_name_equal(field.name, "Location"))
            || (metadata.accept_ranges && header_name_equal(field.name, "Accept-Ranges")) {
            continue;
        }
        if add_header(response, field.name, field.value) != ResponseError.None {
            return response.error;
        }
    }
    if metadata.etag.len > 0 && add_header(response, "ETag", metadata.etag) != ResponseError.None {
        return response.error;
    }
    if metadata.last_modified.len > 0
        && add_header(response, "Last-Modified", metadata.last_modified) != ResponseError.None {
        return response.error;
    }
    if metadata.content_type.len > 0
        && add_header(response, "Content-Type", metadata.content_type) != ResponseError.None {
        return response.error;
    }
    if metadata.content_range.len > 0
        && add_header(response, "Content-Range", metadata.content_range) != ResponseError.None {
        return response.error;
    }
    if metadata.accept_ranges && add_header(response, "Accept-Ranges", "bytes") != ResponseError.None {
        return response.error;
    }
    if metadata.content_encoding.len > 0
        && add_header(response, "Content-Encoding", metadata.content_encoding) != ResponseError.None {
        return response.error;
    }
    if metadata.location.len > 0 && add_header(response, "Location", metadata.location) != ResponseError.None {
        return response.error;
    }
    if metadata.vary_accept_encoding && add_header(response, "Vary", "Accept-Encoding") != ResponseError.None {
        return response.error;
    }
    return ResponseError.None;
}
