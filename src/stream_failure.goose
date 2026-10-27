// An explicitly selected callback failure replaces uncommitted output through shared validation.
namespace silly;

import.connection;
import.headers;
import.response;
import.response_policy_headers;
import.response_wire_types;
import.server_buffers;
import.server_options;
import.stream_contract;

fn render_owned_stream_failure(selected: StreamFailureResponse&, connection: Connection&,
    buffers: ConnectionBuffers, options: ServerOptions) {
    var fields: HeaderField[>..] = [];
    var headers: u8[>..] = [];
    var output: u8[>..] = [];
    var response = Response {
        limits: options.limits,
        header_fields: fields,
        header_bytes: headers,
        output: output,
        ..
    };
    var error = prepare_owned_stream_failure(selected, response);
    if error == ResponseError.None {
        error = apply_response_policy(response, connection.response_policy);
    }
    if error == ResponseError.None {
        error = stage_reply(connection, buffers, response, ResponseWireOptions {
                http_minor: connection.http_minor,
                request_method: connection.completion.method,
                close: true,
                ..
            }, options.response_head_bytes_max);
    }
    if error != ResponseError.None {
        build_failure(connection, buffers.head, connection.http_minor);
    }
}

fn prepare_owned_stream_failure(selected: StreamFailureResponse&, response: Response&) -> ResponseError {
    var error = begin_response(response, selected.status);
    if error == ResponseError.None && selected.content_type.len > 0 {
        error = add_header(response, "Content-Type", selected.content_type);
    }
    if error == ResponseError.None {
        error = append_body(response, selected.body);
    }
    if error == ResponseError.None {
        error = prepare_response(response);
    }
    return error;
}
