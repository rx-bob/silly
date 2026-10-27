// Copy kernels keep owned response storage separate from HTTP head bytes.
namespace silly;

import std;

import.connection;
import.context;
import.header_index;
import.headers;
import.http_head_types;
import.http_parser;
import.http_writer;
import.request;
import.response;
import.response_errors;
import.response_wire_types;
import.server_body;
import.server_options;
import.state;

type BufferedContext = Context<NoState, NoStream>;

checkfree fn copy_server_bytes(target: u8[:], source: u8[:]) {
    assert(target.len >= source.len);
    for index in source.len {
        target[index] = source[index];
    }
}

// Handler and renderer frames end before their owners can be discarded or reused.
fn build_reply<D, H, E>(connection: Connection&, buffers: ConnectionBuffers, options: ServerOptions, driver: D&) {
    let input = buffers.input[..connection.scan.head_bytes];
    var fields: HeaderView[>..] = [];
    var index: HeaderIndexEntry[>..] = [];
    let parsed = parse_head(input, fields, index, options.limits);
    if parsed.result != HeadResult.Complete {
        build_head_error(connection, buffers.head, parsed.result);
        return;
    }
    let request = Request {
        method: parsed.method,
        target: parsed.target,
        headers: fields,
        header_index: index,
        body_framing: parsed.framing,
        body_state: RequestBody.Buffered {
            bytes: buffers.request[..connection.request_bytes]
        },
        ..
    };
    let wire_options = ResponseWireOptions {
        http_minor: parsed.http_minor,
        request_method: parsed.method,
        close: connection.close_after_reply,
        ..
    };
    let failure = application_reply(connection, buffers, options, request, wire_options, driver, H);
    if failure.error != ResponseError.None {
        render_reply(connection, buffers, options, wire_options, failure, E);
    }
}

fn application_reply<D, H>(connection: Connection&, buffers: ConnectionBuffers, options: ServerOptions,
    request: Request, wire_options: ResponseWireOptions, driver: D&) -> ResponseFailure {
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
    var app = NoState {
    };
    var ctx = BufferedContext {
        request: request,
        response: response,
        app: app
    };
    H(driver, ctx);
    let failure = response_failure(response);
    if failure.error != ResponseError.None {
        return failure;
    }
    let error = stage_reply(connection, buffers, response, wire_options, options.response_head_bytes_max);
    return ResponseFailure {
        kind: if error == ResponseError.None {
            ResponseFailureKind.None
        } else {
            ResponseFailureKind.Serialization
        },
        error: error,
        ..
    };
}

fn render_reply<E>(connection: Connection&, buffers: ConnectionBuffers, options: ServerOptions,
    wire_options: ResponseWireOptions, failure: ResponseFailure) {
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
    E(response, failure);
    if response_failure(response).error != ResponseError.None {
        build_failure(connection, buffers.head, wire_options.http_minor);
        return;
    }
    let error = stage_reply(connection, buffers, response, wire_options, options.response_head_bytes_max);
    if error != ResponseError.None {
        // Renderer failure has one deterministic fallback; never recurse into application code.
        build_failure(connection, buffers.head, wire_options.http_minor);
    }
}

fn stage_reply(connection: Connection&, buffers: ConnectionBuffers, response: Response&,
    wire_options: ResponseWireOptions, cap: i64) -> ResponseError {
    var wire: u8[>..] = [];
    if response.output.len > buffers.body.len {
        return ResponseError.OutputLimit;
    }
    let plan = prepare_response_head(wire, response, wire_options, min(cap, buffers.head.len));
    if plan.error != ResponseError.None {
        return plan.error;
    }
    let error = commit_response(response);
    if error != ResponseError.None {
        return error;
    }
    copy_server_bytes(buffers.head, wire);
    copy_server_bytes(buffers.body, response.output[..plan.body_bytes]);
    connection.close_after_reply = plan.close;
    connection.head_bytes = wire.len;
    connection.body_bytes = plan.body_bytes;
    connection.head_sent = 0;
    connection.body_sent = 0;
    connection.phase = ConnectionPhase.Writing;
    return ResponseError.None;
}

fn build_head_error(connection: Connection&, head: u8[:], result: HeadResult) {
    build_status_error(connection, head, head_status(result));
}

fn build_status_error(connection: Connection&, head: u8[:], status: i32) {
    connection.close_after_reply = true;
    assert(status >= 400);
    let bytes = str("HTTP/1.", connection.http_minor, " ", status, " ", response_reason(status),
        "\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
    copy_server_bytes(head, bytes);
    connection.head_bytes = bytes.len;
    connection.body_bytes = 0;
    connection.head_sent = 0;
    connection.body_sent = 0;
    connection.phase = ConnectionPhase.Writing;
}

fn build_failure(connection: Connection&, head: u8[:], http_minor: i32 = 1) {
    connection.close_after_reply = true;
    let bytes = str("HTTP/1.", http_minor,
        " 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
    copy_server_bytes(head, bytes);
    connection.head_bytes = bytes.len;
    connection.body_bytes = 0;
    connection.head_sent = 0;
    connection.body_sent = 0;
    connection.phase = ConnectionPhase.Writing;
}

fn empty_reply(ctx: BufferedContext&, status: i32) {
    if begin_response(ctx.response, status) == ResponseError.None {
        prepare_response(ctx.response);
    }
}
