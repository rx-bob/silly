// Real sockets prove parsed indexes reach handlers without losing raw or repeated values.
namespace header_access_server_test;

import silly from "..";

import std;

let DEADLINE_MS = 10000;

var handled_count: i64 = 0;

type Context = silly::Context<silly::NoState, silly::NoStream>;

struct Handled {
    number: i64,
}

struct Stopped {
    ok: bool,
    handled: i64,
}

fn inspect_fields(ctx: Context&) {
    assert(ctx.request.header_index.len == ctx.request.headers.len);
    assert(ctx.request.header_index.len == 9);
    let wire = valid_request();
    for entry in ctx.request.header_index {
        let source = entry.source;
        let field = ctx.request.headers[entry.field_index];
        assert(wire[source.name_start..source.name_start + source.name_bytes] == field.name);
        assert(wire[source.value_start..source.value_start + source.value_bytes] == field.value);
    }
    assert(ctx.header_raw("authorization").value == "Bearer session \t");
    assert(ctx.header("AUTHORIZATION").value == "Bearer session");
    assert(ctx.header_wire("Authorization").value == " \tBearer session \t");
    assert(!ctx.header("Missing").present);
    assert(ctx.header_wire("X-Empty").present);
    assert(ctx.header_wire("X-Empty").value == "");
    assert(ctx.header_wire("X-Whitespace").value == " \t ");
    assert(ctx.header("X-Whitespace").value == "");
}

fn inspect_repetitions(ctx: Context&) {
    var values = ctx.header_values("X-MCP-USER-ID", silly::HeaderValueMode.Wire);
    assert(silly::next_header(values).value == " first ");
    assert(silly::next_header(values).value == "\tsecond\t");
    assert(!silly::next_header(values).present);
    assert(!silly::next_header(values).present);
    assert(ctx.header("X-Zitadel-User-Id").value == "unverified-id");
    assert(ctx.header_raw("X-Forwarded-User").value == "unverified-user ");
    assert(ctx.header_wire("X-Arbitrary").value == " a,b,c");
}

fn handle(ctx: Context&) {
    assert(ctx.request.method == "GET");
    assert(ctx.request.target == "/headers");
    inspect_fields(ctx);
    inspect_repetitions(ctx);
    handled_count += 1;
    assert(qput(Handled {
            number: handled_count
        }));
    assert(silly::begin_response(ctx.response, 200) == silly::ResponseError.None);
    assert(silly::append_body(ctx.response, "ok") == silly::ResponseError.None);
    assert(silly::prepare_response(ctx.response) == silly::ResponseError.None);
}

fn valid_request() -> u8[>..] {
    return str("GET /headers HTTP/1.1\r\nHost: localhost\r\nAuthorization: \tBearer session \t\r\n",
        "X-Mcp-User-Id: first \r\nx-mcp-user-id:\tsecond\t\r\nX-Zitadel-User-Id: unverified-id\r\n",
        "X-Forwarded-User: unverified-user \r\nX-Empty:\r\nX-Whitespace: \t \r\nX-Arbitrary: a,b,c\r\n\r\n");
}

thread_fn serve(listener: i32, wake: i32) {
    let options = silly::ServerOptions {
        port: 0,
        limits: silly::Limits {
            head_bytes_max: 1024,
            header_count_max: 16,
            header_bytes_max: 768,
            output_bytes_max: 32,
            request_line_bytes_max: 64,
            header_line_bytes_max: 64,
            header_section_bytes_max: 768,
            ..
        },
        connections_max: 4,
        response_head_bytes_max: 256,
        buffer_bytes_max: 8192,
        work_bytes_per_turn: 7,
        accepts_per_turn: 4,
        poll_timeout_ms: 10,
        ..
    };
    let result = silly::run_server(options, silly_transport::Descriptor {
            fd: listener
        },
        silly_transport::Descriptor {
            fd: wake
        }, handle);
    assert(qput(Stopped {
            ok: result.ok,
            handled: handled_count
        }));
}

fn now() -> i64 {
    let result = silly_transport::monotonic_ms();
    assert(result.status == silly_transport::IoStatus.Ready);
    return result.count;
}

fn ready(socket: silly_transport::Descriptor, interest: i32, deadline: i64) {
    let fds: i32[1] = [socket.fd];
    let interests: i32[1] = [interest];
    var events: i32[1] = [0];
    while now() < deadline {
        let result = silly_transport::poll(fds, interests, events, 10);
        assert(result.status == silly_transport::IoStatus.Ready
            || result.status == silly_transport::IoStatus.Interrupted);
        if result.status == silly_transport::IoStatus.Ready && events[0] != 0 {
            return;
        }
    }
    abort("header access integration readiness timed out");
}

fn connect(port: i32) -> silly_transport::Descriptor {
    let result = silly_transport::connect("127.0.0.1", port);
    assert(result.status == silly_transport::IoStatus.Ready
        || result.status == silly_transport::IoStatus.WouldBlock);
    if result.status == silly_transport::IoStatus.WouldBlock {
        ready(result.descriptor, silly_transport::WRITE, now() + DEADLINE_MS);
        assert(silly_transport::finish_connect(result.descriptor).status == silly_transport::IoStatus.Ready);
    }
    return result.descriptor;
}

fn send_bytes(socket: silly_transport::Descriptor, bytes: u8[:]) {
    let deadline = now() + DEADLINE_MS;
    var offset = 0;
    while offset < bytes.len {
        assert(now() < deadline);
        let result = silly_transport::write_parts(socket, bytes[offset..], "");
        match result.status {
            Ready => {
                assert(result.count > 0);
                offset += result.count;
            },
            WouldBlock => {
                ready(socket, silly_transport::WRITE, deadline);
            },
            Interrupted => {
            },
            _ => {
                assert(false);
            },
        }
    }
}

fn receive_closed(socket: silly_transport::Descriptor) -> u8[>..] {
    var output: u8[>..] = [];
    var bytes: u8[1024] = [0; 1024];
    let deadline = now() + DEADLINE_MS;
    while now() < deadline {
        let result = silly_transport::read(socket, bytes);
        match result.status {
            Ready => {
                assert(result.count <= 4096 - output.len);
                output.append(bytes[..result.count]);
            },
            Closed => {
                return output;
            },
            WouldBlock => {
                ready(socket, silly_transport::READ, deadline);
            },
            Interrupted => {
            },
            _ => {
                assert(false);
            },
        }
    }
    abort("header access integration response timed out");
}

fn rejected(port: i32, request: u8[:], status: i32) {
    var client = connect(port);
    send_bytes(client, request);
    let response = receive_closed(client);
    // Closing with unread attack bytes can reset TCP and truncate the error response.
    // Any received status bytes must match the rejection; the connection must close.
    let prefix = str("HTTP/1.1 ", status, " ");
    if response.len < prefix.len {
        assert(starts_with(prefix, response));
    } else {
        assert(starts_with(response, prefix));
    }
    let separator = find(response, "\r\n\r\n");
    if separator >= 0 {
        assert(find(response, "Connection: close\r\n") >= 0);
        assert(response[separator + 4..].len == 0);
    }
    let event, present = qpoll<Handled>();
    assert(!present);
    silly_transport::close(client);
}

fn valid_fragments(port: i32, expected: i64) {
    var client = connect(port);
    let request = valid_request();
    for index in request.len {
        send_bytes(client, request[index..index + 1]);
    }
    let response = receive_closed(client);
    assert(starts_with(response, "HTTP/1.1 200 "));
    assert(find(response, "Content-Length: 2\r\n") >= 0);
    let separator = find(response, "\r\n\r\n");
    assert(separator >= 0);
    assert(response[separator + 4..] == "ok");
    let event, present = qget<Handled>(DEADLINE_MS);
    assert(present);
    assert(event.number == expected);
    silly_transport::close(client);
}

fn singleton_rejection(port: i32) {
    let poison = valid_request();
    rejected(port, str("GET /headers HTTP/1.1\r\nHost: localhost\r\n",
        "Authorization: Bearer a\r\nAuthorization: Bearer b\r\n\r\n", poison), 400);
}

fn run() {
    qlimit<Handled>(4);
    qlimit<Stopped>(1);
    var listener = silly_transport::listen("127.0.0.1", 0, 8);
    assert(listener.status == silly_transport::IoStatus.Ready);
    let port = silly_transport::local_port(listener.descriptor);
    assert(port.status == silly_transport::IoStatus.Ready);
    var wake = silly_transport::wake_pair();
    assert(wake.status == silly_transport::IoStatus.Ready);
    let worker = thread_spawn(serve, listener.descriptor.fd, wake.reader.fd);
    listener.descriptor.fd = -1;
    wake.reader.fd = -1;
    valid_fragments(port.count as i32, 1);
    singleton_rejection(port.count as i32);
    valid_fragments(port.count as i32, 2);
    assert(silly_transport::notify(wake.writer).status == silly_transport::IoStatus.Ready);
    let stopped, present = qget<Stopped>(DEADLINE_MS);
    assert(present);
    assert(stopped.ok);
    assert(stopped.handled == 2);
    assert(thread_wait(worker));
    silly_transport::close(wake.writer);
    print("indexed header socket access passed");
}

fn::main() {
    header_access_server_test::run();
}
