// Server option arithmetic, connection generations and bounded real-socket write progress.
namespace server_state_test;

import silly from "../../";

import std;

fn option_bounds() {
    let defaults = silly::ServerOptions {
    };
    assert(silly::valid_server_options(defaults));
    var options = defaults;
    options.port = -1;
    assert(!silly::valid_server_options(options));
    options.port = 65536;
    assert(!silly::valid_server_options(options));
    options = defaults;
    options.connections_max = 0;
    assert(!silly::valid_server_options(options));
    options.connections_max = silly_transport::POLL_MAX - 1;
    assert(!silly::valid_server_options(options));
    options = defaults;
    options.work_bytes_per_turn = 0;
    assert(!silly::valid_server_options(options));
    options = defaults;
    options.poll_timeout_ms = -1;
    assert(!silly::valid_server_options(options));
    options = defaults;
    options.idle_timeout_ms = 99;
    assert(!silly::valid_server_options(options));
    options = defaults;
    options.accepts_per_turn = options.connections_max + 1;
    assert(!silly::valid_server_options(options));
    options = defaults;
    options.response_head_bytes_max = 127;
    assert(!silly::valid_server_options(options));
}

fn arithmetic_bounds() {
    var options = silly::ServerOptions {
        limits: silly::Limits {
            head_bytes_max: 64,
            body_bytes_max: 0,
            output_bytes_max: 256,
            ..
        },
        connections_max: 2,
        response_head_bytes_max: 128,
        buffer_bytes_max: 1024,
        accepts_per_turn: 2,
        body_read_bytes_max: 64,
        ..
    };
    assert(silly::valid_server_options(options));
    options.buffer_bytes_max -= 1;
    assert(!silly::valid_server_options(options));
    options.buffer_bytes_max = 0x7fffffffffffffff;
    options.limits.output_bytes_max = 0x7fffffffffffffff;
    assert(!silly::valid_server_options(options));
    options.limits.output_bytes_max = 256;
    options.limits.head_bytes_max = 0x7fffffffffffffff;
    assert(!silly::valid_server_options(options));
    options.limits.head_bytes_max = 64;
    options.response_head_bytes_max = 0x7fffffffffffffff;
    assert(!silly::valid_server_options(options));
    options.response_head_bytes_max = 128;
    options.buffer_bytes_max = -1;
    assert(!silly::valid_server_options(options));
}

fn generation_availability() {
    var slots: silly::Connection[2] = [silly::Connection {
        }; 2];
    assert(silly::available_connection(slots) == 0);
    slots[0].generation = 0xffffffffffffffff;
    assert(silly::available_connection(slots) == 1);
    slots[1].phase = silly::ConnectionPhase.Reading;
    assert(silly::available_connection(slots) == -1);
    silly::release_connection(slots[1]);
    assert(silly::available_connection(slots) == 1);
    silly::release_connection(slots[0]);
    assert(slots[0].generation == 0xffffffffffffffff);
    assert(slots[0].socket.fd == -1);
}

fn connect_client(port: i32) -> silly_transport::Descriptor {
    let client = silly_transport::connect("127.0.0.1", port);
    if client.status == silly_transport::IoStatus.WouldBlock {
        var events: i32[1] = [0];
        assert(silly_transport::poll([client.descriptor.fd], [silly_transport::WRITE], events, 1000).count == 1);
        assert(silly_transport::finish_connect(client.descriptor).status == silly_transport::IoStatus.Ready);
    } else {
        assert(client.status == silly_transport::IoStatus.Ready);
    }
    return client.descriptor;
}

fn accept_generation() {
    var listener = silly_transport::listen("127.0.0.1", 0, 8);
    assert(listener.status == silly_transport::IoStatus.Ready);
    let port = silly_transport::local_port(listener.descriptor);
    assert(port.status == silly_transport::IoStatus.Ready);
    var slots: silly::Connection[1] = [silly::Connection {
        }];
    let options = silly::ServerOptions {
        connections_max: 1,
        accepts_per_turn: 1,
        ..
    };
    for generation in 1..3 {
        var client = connect_client(port.count as i32);
        var events: i32[1] = [0];
        assert(silly_transport::poll([listener.descriptor.fd], [silly_transport::READ], events, 1000).count == 1);
        assert(silly::accept_connections(slots, listener.descriptor, options, 100).status
            == silly_transport::IoStatus.Ready);
        assert(slots[0].generation == generation as u64);
        assert(slots[0].phase == silly::ConnectionPhase.Reading);
        assert(slots[0].input_bytes == 0);
        assert(slots[0].head_sent == 0);
        assert(slots[0].body_sent == 0);
        assert(slots[0].scan.checked_bytes == 0);
        assert(slots[0].active_ms == 100);
        slots[0].input_bytes = 17;
        slots[0].head_sent = 19;
        slots[0].body_sent = 23;
        slots[0].scan.checked_bytes = 17;
        silly::release_connection(slots[0]);
        silly::release_connection(slots[0]);
        assert(slots[0].socket.fd == -1);
        assert(silly_transport::close(client).status == silly_transport::IoStatus.Ready);
    }
    assert(silly_transport::close(listener.descriptor).status == silly_transport::IoStatus.Ready);
}

fn fill_connection(connection: silly::Connection&, head: u8[:], body: u8[:]) {
    for turn in 1024 {
        let before = connection.head_sent + connection.body_sent;
        silly::write_connection(connection, head, body, 4096);
        let after = connection.head_sent + connection.body_sent;
        assert(after >= before);
        assert(after - before <= 4096);
        assert(connection.phase == silly::ConnectionPhase.Writing);
        if after == before {
            assert(after > 0);
            assert(connection.head_sent == head.len);
            silly::write_connection(connection, head, body, 4096);
            assert(connection.head_sent + connection.body_sent == after);
            return;
        }
    }
    abort("bounded connection writes never reached backpressure");
}

fn drain_connection(connection: silly::Connection&, reader: silly_transport::Descriptor, head: u8[:], body: u8[:]) {
    var received: u8[>..] = [];
    var buffer: u8[8192] = [0; 8192];
    for turn in 4096 {
        if connection.phase == silly::ConnectionPhase.Writing {
            let before = connection.head_sent + connection.body_sent;
            silly::write_connection(connection, head, body, 1024);
            assert(connection.head_sent + connection.body_sent - before <= 1024);
        }
        let result = silly_transport::read(reader, buffer);
        if result.status == silly_transport::IoStatus.Ready {
            received.append(buffer[..result.count]);
        } else if result.status == silly_transport::IoStatus.Closed {
            assert(connection.phase == silly::ConnectionPhase.Free);
            assert(connection.socket.fd == -1);
            assert(received.len == head.len + body.len);
            assert(received[..head.len] == head);
            assert(received[head.len..] == body);
            return;
        } else {
            assert(result.status == silly_transport::IoStatus.WouldBlock);
        }
    }
    abort("connection drain exceeded bounded turns");
}

fn connection_pressure() {
    var pair = silly_transport::wake_pair(4096);
    assert(pair.status == silly_transport::IoStatus.Ready);
    let head = "HTTP/1.1 200 OK\r\nContent-Length: 1048576\r\n\r\n";
    var body: u8[>..] = [];
    for index in 1024 * 1024 {
        body.push((index % 251)as u8);
    }
    var connection = silly::Connection {
        socket: pair.writer,
        generation: 1,
        phase: silly::ConnectionPhase.Writing,
        head_bytes: head.len,
        body_bytes: body.len,
        ..
    };
    pair.writer.fd = -1;
    fill_connection(connection, head, body);
    drain_connection(connection, pair.reader, head, body);
    assert(connection.head_sent == head.len);
    assert(connection.body_sent == body.len);
    assert(connection.generation == 1);
    assert(silly_transport::close(pair.reader).status == silly_transport::IoStatus.Ready);
}

fn interim_writes() {
    var pair = silly_transport::wake_pair();
    assert(pair.status == silly_transport::IoStatus.Ready);
    let head = "HTTP/1.1 100 Continue\r\n\r\n";
    var connection = silly::Connection {
        socket: pair.writer,
        phase: silly::ConnectionPhase.Continue,
        head_bytes: head.len,
        ..
    };
    pair.writer.fd = -1;
    for step in 4 {
        silly::write_connection(connection, head, "", 7);
        if step < 3 {
            assert(connection.phase == silly::ConnectionPhase.Continue);
            assert(connection.head_sent == (step + 1) * 7);
        }
    }
    assert(connection.phase == silly::ConnectionPhase.ReadingBody);
    assert(connection.head_sent == 0);
    assert(connection.head_bytes == 0);
    var received: u8[25] = [0; 25];
    let result = silly_transport::read(pair.reader, received);
    assert(result.status == silly_transport::IoStatus.Ready);
    assert(result.count == head.len);
    assert(received == head);
    silly::release_connection(connection);
    silly_transport::close(pair.reader);
}

fn::main() {
    server_state_test::interim_writes();
    server_state_test::option_bounds();
    server_state_test::arithmetic_bounds();
    server_state_test::generation_availability();
    server_state_test::accept_generation();
    server_state_test::connection_pressure();
    print("server state contracts passed");
}
