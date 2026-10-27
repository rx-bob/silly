// Valid-head policies can finish OPTIONS before body collection or 100 Continue.
namespace silly;

import.connection;
import.headers;
import.http_head_types;
import.lifecycle_types;
import.response;
import.response_errors;
import.response_policy_headers;
import.response_wire_types;
import.server_body;
import.server_buffers;
import.server_options;
import.server_request_errors;

fn policy_error<E>(connection: Connection&, buffers: ConnectionBuffers, options: ServerOptions,
    status: i32, error: ResponseError = ResponseError.None) {
    request_error(connection, buffers, options, ResponseFailure {
            kind: ResponseFailureKind.Admission,
            status: status,
            error: error,
            ..
        }, E);
}

fn finish_policy_request<E>(connection: Connection&, buffers: ConnectionBuffers, options: ServerOptions,
    parsed: ParsedHead) -> bool {
    let policy = connection.response_policy;
    if policy.error != ResponseError.None {
        policy_error(connection, buffers, options, 500, policy.error, E);
        return true;
    }
    if policy.cors.early_status != 0 {
        if policy.cors.early_status >= 400 {
            policy_error(connection, buffers, options, policy.cors.early_status, E);
        } else {
            if parsed.framing == BodyFraming.Chunked || parsed.content_length > 0 {
                connection.close_after_reply = true;
            }
            connection.completion.selection = CompletionSelection.Generated;
            prepare_preflight(connection, buffers, options, parsed.http_minor, policy.cors.early_status);
        }
        return true;
    }
    if policy.method_not_allowed {
        policy_error(connection, buffers, options, 405, E);
        return true;
    }
    return false;
}

fn prepare_preflight(connection: Connection&, buffers: ConnectionBuffers, options: ServerOptions,
    minor: i32, status: i32) {
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
    let started = begin_response(response, status);
    if started != ResponseError.None || prepare_response(response) != ResponseError.None {
        build_failure(connection, buffers.head, minor);
        return;
    }
    if apply_response_policy(response, connection.response_policy) != ResponseError.None {
        build_failure(connection, buffers.head, minor);
        return;
    }
    let error = stage_reply(connection, buffers, response, ResponseWireOptions {
            http_minor: minor,
            request_method: "OPTIONS",
            close: connection.close_after_reply,
            ..
        }, options.response_head_bytes_max);
    if error != ResponseError.None {
        build_failure(connection, buffers.head, minor);
    }
}
