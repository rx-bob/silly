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
import.server_options;
import.state;

type BufferedContext = Context<NoState, NoStream>;

checkfree fn copy_server_bytes(target: u8[:], source: u8[:]) {
    assert(target.len >= source.len);
    for index in source.len {
        target[index] = source[index];
    }
}

// All temporary handler views end here. Only copied head/body bytes survive in owning slabs.
fn build_reply<D, H>(connection: Connection&, input: u8[:], head: u8[:], body: u8[:],
    options: ServerOptions, driver: D&) {
    var fields: HeaderView[>..] = [];
    var index: HeaderIndexEntry[>..] = [];
    let parsed = parse_head(input, fields, index, options.limits);
    if parsed.result != HeadResult.Complete {
        build_head_error(connection, head, parsed.result);
        return;
    }
    if parsed.framing == BodyFraming.Chunked || parsed.content_length != 0
        || find_header(fields, "Expect") >= 0 {
        build_head_error(connection, head, HeadResult.UnsupportedBody);
        return;
    }
    var response_fields: HeaderField[>..] = [];
    var response_headers: u8[>..] = [];
    var output: u8[>..] = [];
    var wire: u8[>..] = [];
    var response = Response {
        limits: options.limits,
        header_fields: response_fields,
        header_bytes: response_headers,
        output: output,
        ..
    };
    {
        let request = Request {
            method: parsed.method,
            target: parsed.target,
            headers: fields,
            header_index: index,
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
    }
    if response.phase != ResponsePhase.Prepared {
        build_failure(connection, head);
        return;
    }
    if write_response_head(wire, response, parsed.http_minor, options.response_head_bytes_max) != ResponseError.None {
        build_failure(connection, head);
        return;
    }
    assert(commit_response(response) == ResponseError.None);
    copy_server_bytes(head, wire);
    copy_server_bytes(body, output);
    connection.head_bytes = wire.len;
    connection.body_bytes = if parsed.method == "HEAD" {
        0
    } else {
        output.len
    };
    connection.phase = ConnectionPhase.Writing;
}

fn build_head_error(connection: Connection&, head: u8[:], result: HeadResult) {
    let status = head_status(result);
    assert(status >= 400);
    let bytes = str("HTTP/1.1 ", status, " ", response_reason(status),
        "\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
    copy_server_bytes(head, bytes);
    connection.head_bytes = bytes.len;
    connection.body_bytes = 0;
    connection.phase = ConnectionPhase.Writing;
}

fn build_failure(connection: Connection&, head: u8[:]) {
    let bytes = "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
    copy_server_bytes(head, bytes);
    connection.head_bytes = bytes.len;
    connection.body_bytes = 0;
    connection.phase = ConnectionPhase.Writing;
}

fn empty_reply(ctx: BufferedContext&, status: i32) {
    if begin_response(ctx.response, status) == ResponseError.None {
        prepare_response(ctx.response);
    }
}
