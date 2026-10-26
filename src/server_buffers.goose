// Copy kernels keep owned response storage separate from HTTP head bytes.
namespace silly;

import std;

import.connection;
import.context;
import.headers;
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
fn build_reply<H>(connection: Connection&, input: u8[:], head: u8[:], body: u8[:], options: ServerOptions) {
    var fields: HeaderView[>..] = [];
    let parsed = parse_get_head(input, fields, options.limits);
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
    if parsed.result == HeadResult.Complete {
        let request = Request {
            method: "GET",
            target: parsed.target,
            headers: fields,
            ..
        };
        var app = NoState {
        };
        var ctx = BufferedContext {
            request: request,
            response: response,
            app: app
        };
        H(ctx);
    } else {
        begin_response(response, 400);
        prepare_response(response);
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
    connection.body_bytes = output.len;
    connection.phase = ConnectionPhase.Writing;
}

fn build_failure(connection: Connection&, head: u8[:]) {
    let bytes = "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
    copy_server_bytes(head, bytes);
    connection.head_bytes = bytes.len;
    connection.body_bytes = 0;
    connection.phase = ConnectionPhase.Writing;
}
