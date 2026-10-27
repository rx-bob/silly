// Real loopback integration: one unread large response cannot block a second client.
namespace server_test;

import silly from "..";

import std;

let LARGE_BYTES = 4 * 1024 * 1024;
let DEADLINE_MS = 10000;

type Context = silly::Context<silly::NoState, silly::NoStream>;

struct HandlerSeen {
    slow: bool,
}

struct ServerStopped {
    ok: bool,
}

fn handle(ctx: Context&) {
    assert(silly::begin_response(ctx.response, 200) == silly::ResponseError.None);
    if ctx.request.target == "/slow" {
        let chunk: u8[4096] = ['x'; 4096];
        for index in LARGE_BYTES / chunk.len {
            assert(silly::append_body(ctx.response, chunk) == silly::ResponseError.None);
        }
        assert(silly::prepare_response(ctx.response) == silly::ResponseError.None);
        assert(qput(HandlerSeen {
                slow: true
            }));
    } else {
        assert(silly::append_body(ctx.response, "hello") == silly::ResponseError.None);
        assert(silly::prepare_response(ctx.response) == silly::ResponseError.None);
    }
}

thread_fn server(listener: i32, wake: i32) {
    let options = silly::ServerOptions {
        port: 0,
        limits: silly::Limits {
            body_bytes_max: 0,
            output_bytes_max: LARGE_BYTES,
            ..
        },
        connections_max: 4,
        buffer_bytes_max: 32 * 1024 * 1024,
        work_bytes_per_turn: 4096,
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
    assert(qput(ServerStopped {
            ok: result.ok
        }));
}

fn now() -> i64 {
    let result = silly_transport::monotonic_ms();
    assert(result.status == silly_transport::IoStatus.Ready);
    return result.count;
}

fn await_ready(socket: silly_transport::Descriptor, interest: i32, deadline: i64) {
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
    abort("loopback readiness timed out");
}

fn connect(port: i32) -> silly_transport::Descriptor {
    let result = silly_transport::connect("127.0.0.1", port);
    assert(result.status == silly_transport::IoStatus.Ready
        || result.status == silly_transport::IoStatus.WouldBlock);
    let deadline = now() + DEADLINE_MS;
    if result.status == silly_transport::IoStatus.WouldBlock {
        await_ready(result.descriptor, silly_transport::WRITE, deadline);
        assert(silly_transport::finish_connect(result.descriptor).status == silly_transport::IoStatus.Ready);
    }
    return result.descriptor;
}

fn send_request(socket: silly_transport::Descriptor, path: u8[:]) {
    let request = str("GET ", path, " HTTP/1.1\r\nHost: localhost\r\n\r\n");
    let deadline = now() + DEADLINE_MS;
    var offset = 0;
    while offset < request.len {
        assert(now() < deadline);
        let result = silly_transport::write_parts(socket, request[offset..], "");
        match result.status {
            Ready => {
                assert(result.count > 0);
                offset += result.count;
            },
            WouldBlock => {
                await_ready(socket, silly_transport::WRITE, deadline);
            },
            Interrupted => {
            },
            _ => {
                assert(false);
            },
        }
    }
}

fn receive_closed(socket: silly_transport::Descriptor, capacity: i64) -> u8[>..] {
    var output: u8[>..] = [];
    var buffer: u8[16384] = [0; 16384];
    let deadline = now() + DEADLINE_MS;
    while now() < deadline {
        let result = silly_transport::read(socket, buffer);
        match result.status {
            Ready => {
                assert(result.count > 0);
                assert(result.count <= capacity - output.len);
                output.append(buffer[..result.count]);
            },
            Closed => {
                return output;
            },
            WouldBlock => {
                await_ready(socket, silly_transport::READ, deadline);
            },
            Interrupted => {
            },
            _ => {
                assert(false);
            },
        }
    }
    abort("loopback receive timed out");
}

fn verify_clients(port: i32, wake: silly_transport::Descriptor) {
    var slow = connect(port);
    assert(silly_transport::set_receive_buffer(slow, 64 * 1024).status == silly_transport::IoStatus.Ready);
    send_request(slow, "/slow");
    let seen, received = qget<HandlerSeen>(DEADLINE_MS);
    assert(received);
    assert(seen.slow);
    var fast = connect(port);
    send_request(fast, "/hello");
    let reply = receive_closed(fast, 4096);
    assert(starts_with(reply, "HTTP/1.1 200 "));
    assert(find(reply, "Content-Length: 5\r\n") >= 0);
    assert(find(reply, "Connection: close\r\n") >= 0);
    let separator = find(reply, "\r\n\r\n");
    assert(separator >= 0);
    assert(reply[separator + 4..] == "hello");
    assert(silly_transport::close(fast).status == silly_transport::IoStatus.Ready);
    assert(silly_transport::notify(wake).status == silly_transport::IoStatus.Ready);
    let stopped, finished = qget<ServerStopped>(DEADLINE_MS);
    assert(finished);
    assert(stopped.ok);
    assert(silly_transport::set_receive_buffer(slow, LARGE_BYTES).status == silly_transport::IoStatus.Ready);
    let pending = receive_closed(slow, LARGE_BYTES + 4096);
    let head_end = find(pending, "\r\n\r\n");
    assert(head_end >= 0);
    assert(find(pending, "Content-Length: 4194304\r\n") >= 0);
    assert(pending.len - head_end - 4 < LARGE_BYTES);
    assert(silly_transport::close(slow).status == silly_transport::IoStatus.Ready);
}

fn run() {
    qlimit<HandlerSeen>(1);
    qlimit<ServerStopped>(1);
    var listener = silly_transport::listen("127.0.0.1", 0, 8);
    assert(listener.status == silly_transport::IoStatus.Ready);
    let port = silly_transport::local_port(listener.descriptor);
    assert(port.status == silly_transport::IoStatus.Ready);
    var wake = silly_transport::wake_pair();
    assert(wake.status == silly_transport::IoStatus.Ready);
    let worker = thread_spawn(server, listener.descriptor.fd, wake.reader.fd);
    listener.descriptor.fd = -1;
    wake.reader.fd = -1;
    verify_clients(port.count as i32, wake.writer);
    assert(thread_wait(worker));
    assert(silly_transport::close(wake.writer).status == silly_transport::IoStatus.Ready);
    print("loopback and nonreader fairness passed");
}

fn::main() {
    server_test::run();
}
