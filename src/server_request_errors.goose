// Only precommit, writable failures enter the configured renderer; framing errors close.
namespace silly;

import.body_types;
import.connection;
import.http_head_types;
import.http_request_line;
import.response_errors;
import.response_wire_types;
import.server_body;
import.server_buffers;
import.server_options;
import.transport;

fn request_error<E>(connection: Connection&, buffers: ConnectionBuffers, options: ServerOptions,
    failure: ResponseFailure) {
    connection.close_after_reply = true;
    var wire = ResponseWireOptions {
        http_minor: connection.http_minor,
        close: true,
        ..
    };
    if connection.scan.request_line_end >= 0 {
        let line = parse_request_line(buffers.input[..connection.scan.request_line_end]);
        if line.result == HeadResult.Complete {
            wire.http_minor = line.http_minor;
            wire.request_method = line.method;
        }
    }
    render_reply(connection, buffers, options, wire, failure, E);
}

fn request_head_error<E>(connection: Connection&, buffers: ConnectionBuffers, options: ServerOptions,
    result: HeadResult) {
    request_error(connection, buffers, options, ResponseFailure {
            kind: ResponseFailureKind.RequestHead,
            status: head_status(result),
            head_error: result,
            ..
        }, E);
}

fn request_body_error<E>(connection: Connection&, buffers: ConnectionBuffers, options: ServerOptions,
    result: BodyStatus) {
    request_error(connection, buffers, options, ResponseFailure {
            kind: ResponseFailureKind.RequestBody,
            status: if result == BodyStatus.NeedOutput {
                413
            } else {
                body_status_code(result)
            },
            body_error: result,
            ..
        }, E);
}

fn request_eof<E>(connection: Connection&, buffers: ConnectionBuffers, options: ServerOptions) {
    if connection.phase == ConnectionPhase.Reading && connection.input_bytes == 0 {
        release_connection(connection);
        return;
    }
    let body = connection.phase == ConnectionPhase.ReadingBody;
    request_error(connection, buffers, options, ResponseFailure {
            kind: if body {
                ResponseFailureKind.RequestBody
            } else {
                ResponseFailureKind.RequestHead
            },
            status: 400,
            head_error: if body {
                HeadResult.Complete
            } else {
                HeadResult.Truncated
            },
            body_error: if body {
                BodyStatus.Truncated
            } else {
                BodyStatus.Complete
            },
            transport_status: silly_transport::IoStatus.Closed,
            ..
        }, E);
}

fn request_timeout<E>(connection: Connection&, buffers: ConnectionBuffers, options: ServerOptions) {
    if (connection.phase == ConnectionPhase.Reading && connection.input_bytes > 0)
        || connection.phase == ConnectionPhase.ReadingBody {
        request_error(connection, buffers, options, ResponseFailure {
                kind: ResponseFailureKind.Timeout,
                status: 408,
                ..
            }, E);
    } else {
        release_connection(connection);
    }
}
