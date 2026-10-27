// Local socket helpers keep request/response work bounded and expose interim responses.
namespace body_socket;

import silly from "..";

import std;

let DEADLINE_MS = 60000;

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
    abort("body socket readiness timed out");
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
    var offset: i64 = 0;
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
    abort("body socket response timed out");
}

fn interim(socket: silly_transport::Descriptor) {
    let expected = "HTTP/1.1 100 Continue\r\n\r\n";
    var bytes: u8[25] = [0; 25];
    var count: i64 = 0;
    let deadline = now() + DEADLINE_MS;
    while count < bytes.len {
        let result = silly_transport::read(socket, bytes[count..]);
        match result.status {
            Ready => {
                assert(result.count > 0);
                count += result.count;
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
    assert(bytes == expected);
}

fn valid_response(socket: silly_transport::Descriptor, minor: i32 = 1) {
    let response = receive_closed(socket);
    assert(starts_with(response, str("HTTP/1.", minor, " 200 ")));
    assert(find(response, "100 Continue") < 0);
    assert(find(response, "Content-Length: 2\r\n") >= 0);
    let end = find(response, "\r\n\r\n");
    assert(end >= 0);
    assert(response[end + 4..] == "ok");
}

fn rejected(port: i32, request: u8[:], status: i32) {
    var client = connect(port);
    send_bytes(client, request);
    let response = receive_closed(client);
    let expected = str("HTTP/1.1 ", status, " ");
    // Unread rejected bytes may reset TCP; available error status bytes must agree.
    if response.len < expected.len {
        assert(starts_with(expected, response));
    } else {
        assert(starts_with(response, expected));
    }
    assert(find(response, "100 Continue") < 0);
    silly_transport::close(client);
}
