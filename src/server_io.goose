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
import.lifecycle_types;
import.response;
import.response_errors;
import.response_policy;
import.server_body;
import.server_buffers;
import.server_observer;
import.server_options;
import.server_policy;
import.server_request_errors;
import.state;
import.transport;
import.wire_transfer;

struct AdmittedHead {
    parsed: ParsedHead,
    fields: const HeaderView[:],
    admission: BodyAdmission,
}

fn read_connection<D, H, E, O>(connection: Connection&, buffers: ConnectionBuffers,
    options: ServerOptions, driver: D&) {
    if connection.phase == ConnectionPhase.ReadingBody {
        read_request_body(connection, buffers, options, driver, H, E, O);
        return;
    }
    if !read_staging(connection, buffers, options, E) {
        return;
    }
    consume_request_head(connection, buffers, options, driver, H, E, O);
}

// Never refill staging until all queued bytes have been consumed.
fn read_staging<E>(connection: Connection&, buffers: ConnectionBuffers, options: ServerOptions) -> bool {
    if connection.staged_read < connection.staged_bytes {
        return true;
    }
    let result = silly_transport::read(connection.socket, buffers.staging);
    if result.status == silly_transport::IoStatus.Ready {
        connection.staged_read = 0;
        connection.staged_bytes = result.count;
        connection.received_bytes += result.count;
        return true;
    }
    if result.status == silly_transport::IoStatus.Closed {
        request_eof(connection, buffers, options, E);
    } else if result.status != silly_transport::IoStatus.WouldBlock
        && result.status != silly_transport::IoStatus.Interrupted {
        connection.completion.system_error = result.error;
        release_connection(connection);
    }
    return false;
}

fn consume_request_head<D, H, E, O>(connection: Connection&, buffers: ConnectionBuffers,
    options: ServerOptions, driver: D&) {
    let space = buffers.input.len - connection.input_bytes;
    let count = min(space, connection.staged_bytes - connection.staged_read);
    copy_server_bytes(buffers.input[connection.input_bytes..],
        buffers.staging[connection.staged_read..connection.staged_read + count]);
    if count > 0 {
        connection.completion_pending = true;
    }
    connection.input_bytes += count;
    connection.staged_read += count;
    let scanned = scan_head(connection.scan, buffers.input[..connection.input_bytes], options.limits);
    snapshot_request(connection, buffers.input[..connection.input_bytes]);
    if scanned == HeadResult.Complete {
        // All over-read bytes came from this staging segment; keep them for body/next request.
        connection.staged_read -= connection.input_bytes - connection.scan.head_bytes;
        connection.input_bytes = connection.scan.head_bytes;
        begin_request_body(connection, buffers, options, driver, H, E, O);
        if connection.phase == ConnectionPhase.ReadingBody {
            consume_request_body(connection, buffers, options, driver, H, E, O);
        }
    } else if scanned != HeadResult.NeedMore {
        request_head_error(connection, buffers, options, scanned, E);
    }
}

fn begin_request_body<D, H, E, O>(connection: Connection&, buffers: ConnectionBuffers,
    options: ServerOptions, driver: D&) {
    var fields: HeaderView[>..] = [];
    var index: HeaderIndexEntry[>..] = [];
    let parsed = parse_head(buffers.input[..connection.scan.head_bytes], fields, index, options.limits);
    if parsed.result != HeadResult.Complete {
        request_head_error(connection, buffers, options, parsed.result, E);
        return;
    }
    connection.http_minor = parsed.http_minor;
    connection.close_after_reply = !request_persistent(fields, parsed.http_minor);
    connection.response_policy = resolve_response_policy(driver, parsed, fields);
    let cap = min(options.limits.body_bytes_max, options.body_limits.bytes_max);
    let admission = body_admission(driver, parsed, cap);
    connection.execution_lane = admission.execution_lane;
    connection.completion.route_id = admission.route_id;
    connection.completion.selection = admission.selection;
    if finish_policy_request(connection, buffers, options, parsed, E) {
        return;
    }
    continue_request_body(connection, buffers, options, AdmittedHead {
            parsed: parsed,
            fields: fields,
            admission: admission,
        }, driver, H, E, O);
}

fn continue_request_body<D, H, E, O>(connection: Connection&, buffers: ConnectionBuffers,
    options: ServerOptions, head: AdmittedHead, driver: D&) {
    let parsed = head.parsed;
    let admission = head.admission;
    if admission.complete_response {
        // Generated method responses precede 100 Continue. Unread bodies prohibit reuse.
        if parsed.framing == BodyFraming.Chunked || parsed.content_length > 0 {
            connection.close_after_reply = true;
        }
        build_reply(connection, buffers, options, driver, H, E, O);
        return;
    }
    let expectation = request_expectation(head.fields);
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
        if admission.status == 0 && expectation != 417 {
            request_body_error(connection, buffers, options, connection.reader.status, E);
        } else {
            request_error(connection, buffers, options, ResponseFailure {
                    kind: ResponseFailureKind.Admission,
                    status: status,
                    ..
                }, E);
        }
        return;
    }
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

fn read_request_body<D, H, E, O>(connection: Connection&, buffers: ConnectionBuffers,
    options: ServerOptions, driver: D&) {
    if read_staging(connection, buffers, options, E) {
        consume_request_body(connection, buffers, options, driver, H, E, O);
    }
}

fn consume_request_body<D, H, E, O>(connection: Connection&, buffers: ConnectionBuffers,
    options: ServerOptions, driver: D&) {
    let input = buffers.staging[connection.staged_read..connection.staged_bytes];
    let output = buffers.request[connection.request_bytes..];
    let result = read_body(connection.reader, input, output, options.work_bytes_per_turn);
    connection.staged_read += result.consumed;
    connection.request_bytes += result.produced;
    if result.status == BodyStatus.Complete {
        build_reply(connection, buffers, options, driver, H, E, O);
    } else if result.status != BodyStatus.NeedInput && result.status != BodyStatus.Progress {
        request_body_error(connection, buffers, options, result.status, E);
    }
}

fn write_connection(connection: Connection&, head: u8[:], body: u8[:], budget: i64) {
    var driver = NoState {
    };
    var hooks = HookState {
    };
    write_connection_observed(connection, head, body, budget, driver, hooks, no_server_observer);
}

fn write_connection_observed<D, O>(connection: Connection&, head: u8[:], body: u8[:], budget: i64,
    driver: D&, hooks: HookState&) {
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
    connection.completion.wire_bytes += result.count;
    connection.head_sent = cursor.prefix_sent;
    connection.body_sent = cursor.payload_sent;
    if result.status == WireStatus.Complete {
        if connection.phase == ConnectionPhase.Continue {
            connection.phase = ConnectionPhase.ReadingBody;
            connection.head_bytes = 0;
            connection.head_sent = 0;
        } else {
            finish_transfer(connection, driver, hooks, TransferOutcome.Delivered, O);
            if connection.close_after_reply || connection.draining {
                release_connection(connection);
            } else {
                reset_connection(connection);
            }
        }
    } else if result.status == WireStatus.Failed || result.status == WireStatus.InvalidState {
        connection.completion.system_error = result.system_error;
        finish_transfer(connection, driver, hooks, TransferOutcome.Cancelled, O);
        release_connection(connection);
    }
}
