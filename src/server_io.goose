// One bounded socket read per turn; decoded input and response output have distinct owners.
namespace silly;

import std;

import.body_reader;
import.body_types;
import.connection;
import.header_index;
import.headers;
import.http_head_types;
import.http_parser;
import.http_writer;
import.response;
import.server_body;
import.server_buffers;
import.server_options;
import.transport;
import.wire_transfer;

fn read_connection<D, H, E>(connection: Connection&, buffers: ConnectionBuffers, options: ServerOptions, driver: D&) {
    if connection.phase == ConnectionPhase.ReadingBody {
        read_request_body(connection, buffers, options, driver, H, E);
        return;
    }
    let space = buffers.input.len - connection.input_bytes;
    if space == 0 {
        build_status_error(connection, buffers.head, 431);
        return;
    }
    let count = min(space, server_read_bytes(options));
    let destination = buffers.input[connection.input_bytes..connection.input_bytes + count];
    let result = silly_transport::read(connection.socket, destination);
    if result.status == silly_transport::IoStatus.Ready {
        connection.input_bytes += result.count;
        connection.received_bytes += result.count;
        let scanned = scan_head(connection.scan, buffers.input[..connection.input_bytes], options.limits);
        if scanned == HeadResult.Complete {
            begin_request_body(connection, buffers, options, driver, H, E);
            if connection.phase == ConnectionPhase.ReadingBody {
                consume_request_body(connection, buffers, options, driver, H, E);
            }
        } else if scanned != HeadResult.NeedMore {
            build_head_error(connection, buffers.head, scanned);
        }
    } else if result.status == silly_transport::IoStatus.Closed {
        finish_head(connection.scan);
        release_connection(connection);
    } else if result.status != silly_transport::IoStatus.WouldBlock
        && result.status != silly_transport::IoStatus.Interrupted {
        release_connection(connection);
    }
}

fn begin_request_body<D, H, E>(connection: Connection&, buffers: ConnectionBuffers,
    options: ServerOptions, driver: D&) {
    var fields: HeaderView[>..] = [];
    var index: HeaderIndexEntry[>..] = [];
    let parsed = parse_head(buffers.input[..connection.scan.head_bytes], fields, index, options.limits);
    if parsed.result != HeadResult.Complete {
        build_head_error(connection, buffers.head, parsed.result);
        return;
    }
    connection.http_minor = parsed.http_minor;
    let cap = min(options.limits.body_bytes_max, options.body_limits.bytes_max);
    let admission = body_admission(driver, parsed, cap);
    if admission.complete_response {
        // Generated method responses need no body and must precede 100 Continue.
        build_reply(connection, buffers, options, driver, H, E);
        return;
    }
    let expectation = request_expectation(fields);
    var status = admission.status;
    if status == 0 && expectation == 417 {
        status = 417;
    }
    var limits = options.body_limits;
    limits.bytes_max = admission.cap;
    connection.reader = new_body_reader(parsed.framing, parsed.content_length, limits);
    if status == 0 && connection.reader.status != BodyStatus.NeedInput
        && connection.reader.status != BodyStatus.Complete {
        status = body_status_code(connection.reader.status);
    }
    if status != 0 {
        build_status_error(connection, buffers.head, status);
        return;
    }
    let tail = buffers.input[connection.scan.head_bytes..connection.input_bytes];
    copy_server_bytes(buffers.staging, tail);
    connection.staged_bytes = tail.len;
    connection.staged_read = 0;
    connection.phase = ConnectionPhase.ReadingBody;
    if expectation == 100 && parsed.http_minor == 1 && connection.reader.status != BodyStatus.Complete {
        var interim: u8[>..] = [];
        const interim_fields: HeaderView[0] = [];
        let error = write_informational_head(interim, 100, interim_fields, parsed.http_minor, buffers.head.len);
        if error != ResponseError.None {
            build_failure(connection, buffers.head, parsed.http_minor);
            return;
        }
        copy_server_bytes(buffers.head, interim);
        connection.head_bytes = interim.len;
        connection.head_sent = 0;
        connection.body_bytes = 0;
        connection.phase = ConnectionPhase.Continue;
    }
}

fn read_request_body<D, H, E>(connection: Connection&, buffers: ConnectionBuffers, options: ServerOptions, driver: D&) {
    if connection.staged_read < connection.staged_bytes {
        consume_request_body(connection, buffers, options, driver, H, E);
        return;
    }
    let result = silly_transport::read(connection.socket, buffers.staging);
    if result.status == silly_transport::IoStatus.Ready {
        connection.staged_read = 0;
        connection.staged_bytes = result.count;
        connection.received_bytes += result.count;
        consume_request_body(connection, buffers, options, driver, H, E);
    } else if result.status == silly_transport::IoStatus.Closed {
        finish_body(connection.reader);
        release_connection(connection);
    } else if result.status != silly_transport::IoStatus.WouldBlock
        && result.status != silly_transport::IoStatus.Interrupted {
        release_connection(connection);
    }
}

fn consume_request_body<D, H, E>(connection: Connection&, buffers: ConnectionBuffers,
    options: ServerOptions, driver: D&) {
    let input = buffers.staging[connection.staged_read..connection.staged_bytes];
    let output = buffers.request[connection.request_bytes..];
    let result = read_body(connection.reader, input, output, options.work_bytes_per_turn);
    connection.staged_read += result.consumed;
    connection.request_bytes += result.produced;
    if result.status == BodyStatus.Complete {
        build_reply(connection, buffers, options, driver, H, E);
    } else if result.status != BodyStatus.NeedInput && result.status != BodyStatus.Progress {
        build_status_error(connection, buffers.head,
            if result.status == BodyStatus.NeedOutput {
                413
            } else {
                body_status_code(result.status)
            });
    }
}

fn write_connection(connection: Connection&, head: u8[:], body: u8[:], budget: i64) {
    var cursor = WireCursor {
        prefix_sent: connection.head_sent,
        payload_sent: connection.body_sent,
        ..
    };
    let parts = WireParts {
        prefix: head[..connection.head_bytes],
        payload: body[..connection.body_bytes],
        ..
    };
    let result = write_wire(connection.socket, cursor, parts, budget);
    connection.head_sent = cursor.prefix_sent;
    connection.body_sent = cursor.payload_sent;
    if result.status == WireStatus.Complete {
        if connection.phase == ConnectionPhase.Continue {
            connection.phase = ConnectionPhase.ReadingBody;
            connection.head_bytes = 0;
            connection.head_sent = 0;
        } else {
            release_connection(connection);
        }
    } else if result.status == WireStatus.Failed || result.status == WireStatus.InvalidState {
        release_connection(connection);
    }
}
