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
import.server_body;
import.server_buffers;
import.server_options;
import.transport;

fn read_connection<D, H>(connection: Connection&, buffers: ConnectionBuffers, options: ServerOptions, driver: D&) {
    if connection.phase == ConnectionPhase.ReadingBody {
        read_request_body(connection, buffers, options, driver, H);
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
            begin_request_body(connection, buffers, options, driver);
            if connection.phase == ConnectionPhase.ReadingBody {
                consume_request_body(connection, buffers, options, driver, H);
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

fn begin_request_body<D>(connection: Connection&, buffers: ConnectionBuffers, options: ServerOptions, driver: D&) {
    var fields: HeaderView[>..] = [];
    var index: HeaderIndexEntry[>..] = [];
    let parsed = parse_head(buffers.input[..connection.scan.head_bytes], fields, index, options.limits);
    if parsed.result != HeadResult.Complete {
        build_head_error(connection, buffers.head, parsed.result);
        return;
    }
    let cap = min(options.limits.body_bytes_max, options.body_limits.bytes_max);
    let admission = body_admission(driver, parsed, cap);
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
        let interim = "HTTP/1.1 100 Continue\r\n\r\n";
        copy_server_bytes(buffers.head, interim);
        connection.head_bytes = interim.len;
        connection.head_sent = 0;
        connection.body_bytes = 0;
        connection.phase = ConnectionPhase.Continue;
    }
}

fn read_request_body<D, H>(connection: Connection&, buffers: ConnectionBuffers, options: ServerOptions, driver: D&) {
    if connection.staged_read < connection.staged_bytes {
        consume_request_body(connection, buffers, options, driver, H);
        return;
    }
    let result = silly_transport::read(connection.socket, buffers.staging);
    if result.status == silly_transport::IoStatus.Ready {
        connection.staged_read = 0;
        connection.staged_bytes = result.count;
        connection.received_bytes += result.count;
        consume_request_body(connection, buffers, options, driver, H);
    } else if result.status == silly_transport::IoStatus.Closed {
        finish_body(connection.reader);
        release_connection(connection);
    } else if result.status != silly_transport::IoStatus.WouldBlock
        && result.status != silly_transport::IoStatus.Interrupted {
        release_connection(connection);
    }
}

fn consume_request_body<D, H>(connection: Connection&, buffers: ConnectionBuffers,
    options: ServerOptions, driver: D&) {
    let input = buffers.staging[connection.staged_read..connection.staged_bytes];
    let output = buffers.request[connection.request_bytes..];
    let result = read_body(connection.reader, input, output, options.work_bytes_per_turn);
    connection.staged_read += result.consumed;
    connection.request_bytes += result.produced;
    if result.status == BodyStatus.Complete {
        build_reply(connection, buffers, options, driver, H);
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
    let head_count = min(connection.head_bytes - connection.head_sent, budget);
    let body_count = min(connection.body_bytes - connection.body_sent, budget - head_count);
    let result = silly_transport::write_parts(connection.socket,
        head[connection.head_sent..connection.head_sent + head_count],
        body[connection.body_sent..connection.body_sent + body_count]);
    match result.status {
        Ready => {
            let consumed_head = min(result.count, head_count);
            connection.head_sent += consumed_head;
            connection.body_sent += result.count - consumed_head;
            if connection.head_sent == connection.head_bytes && connection.body_sent == connection.body_bytes {
                if connection.phase == ConnectionPhase.Continue {
                    connection.phase = ConnectionPhase.ReadingBody;
                    connection.head_bytes = 0;
                    connection.head_sent = 0;
                } else {
                    release_connection(connection);
                }
            }
        },
        WouldBlock => {
        },
        Interrupted => {
        },
        _ => {
            release_connection(connection);
        },
    }
}
