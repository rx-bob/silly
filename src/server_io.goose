// One bounded syscall per ready connection; interrupted/would-block operations retain offsets.
namespace silly;

import std;

import.connection;
import.http_head_types;
import.http_parser;
import.server_buffers;
import.server_options;
import.transport;

fn read_connection<D, H>(connection: Connection&, input: u8[:], head: u8[:], body: u8[:],
    options: ServerOptions, driver: D&) {
    let space = input.len - connection.input_bytes;
    if space == 0 {
        release_connection(connection);
        return;
    }
    let count = min(space, options.work_bytes_per_turn);
    let destination = input[connection.input_bytes..connection.input_bytes + count];
    let result = silly_transport::read(connection.socket, destination);
    match result.status {
        Ready => {
            connection.input_bytes += result.count;
            let scanned = scan_head(connection.scan, input[..connection.input_bytes], options.limits);
            if scanned == HeadResult.Complete {
                build_reply(connection, input[..connection.scan.head_bytes], head, body, options, driver, H);
            } else if scanned != HeadResult.NeedMore {
                build_head_error(connection, head, scanned);
            }
        },
        WouldBlock => {
        },
        Interrupted => {
        },
        Closed => {
            finish_head(connection.scan);
            release_connection(connection);
        },
        _ => {
            release_connection(connection);
        },
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
                release_connection(connection);
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
