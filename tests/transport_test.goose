// Actual nonblocking sockets: byte-exact partial writes, pressure, disconnect and wakeups.
namespace transport_test;

import silly from "..";

import std;

extern fn silly_test_interrupt_poll() -> i64;

extern fn silly_test_reset_on_close(fd: i32) -> i32;

fn close_pair(pair: silly_transport::PairResult&) {
    assert(silly_transport::close(pair.reader).status == silly_transport::IoStatus.Ready);
    assert(silly_transport::close(pair.writer).status == silly_transport::IoStatus.Ready);
}

fn wake_and_close() {
    var pair = silly_transport::wake_pair();
    assert(pair.status == silly_transport::IoStatus.Ready);
    var fds: i32[1] = [pair.reader.fd];
    const interests: i32[1] = [silly_transport::READ];
    var events: i32[1] = [0];
    assert(silly_transport::poll(fds, interests, events, 0).count == 0);
    assert(silly_transport::drain_wake(pair.reader).status == silly_transport::IoStatus.WouldBlock);
    assert(silly_transport::notify(pair.writer).count == 1);
    assert(silly_transport::poll(fds, interests, events, 100).count == 1);
    assert((events[0] & silly_transport::READ) != 0);
    assert(silly_transport::drain_wake(pair.reader).count == 1);
    assert(silly_transport::close(pair.reader).status == silly_transport::IoStatus.Ready);
    assert(pair.reader.fd == -1);
    assert(silly_transport::close(pair.reader).status == silly_transport::IoStatus.Closed);
    // sendmsg must report EPIPE/ECONNRESET without delivering SIGPIPE to the process.
    assert(silly_transport::notify(pair.writer).status == silly_transport::IoStatus.Closed);
    assert(silly_transport::close(pair.writer).status == silly_transport::IoStatus.Ready);
    var replacement = silly_transport::wake_pair();
    assert(replacement.status == silly_transport::IoStatus.Ready);
    assert(silly_transport::close(pair.reader).status == silly_transport::IoStatus.Closed);
    assert(silly_transport::notify(replacement.writer).count == 1);
    assert(silly_transport::drain_wake(replacement.reader).count == 1);
    close_pair(replacement);
}

fn send_remaining(fd: silly_transport::Descriptor, head: u8[:], body: u8[:], sent: i64)
    -> silly_transport::IoResult {
    if sent < head.len {
        return silly_transport::write_parts(fd, head[sent..], body);
    }
    return silly_transport::write_parts(fd, "", body[sent - head.len..]);
}

fn fill_pressure(fd: silly_transport::Descriptor, head: u8[:], body: u8[:]) -> i64 {
    let total = head.len + body.len;
    var sent = 0;
    var partial = false;
    for turn in 1024 {
        let result = send_remaining(fd, head, body, sent);
        if result.status == silly_transport::IoStatus.WouldBlock {
            assert(partial);
            assert(sent > 0);
            assert(sent < total);
            return sent;
        }
        assert(result.status == silly_transport::IoStatus.Ready);
        assert(result.count > 0);
        assert(result.count <= total - sent);
        partial = partial || result.count < total - sent;
        sent += result.count;
        assert(sent < total);
    }
    abort("socket did not reach bounded backpressure");
    return sent;
}

fn resume_pressure(pair: silly_transport::PairResult, head: u8[:], body: u8[:], initial: i64) {
    var received: u8[>..] = [];
    var sent = initial;
    let total = head.len + body.len;
    var buffer: u8[8192] = [0; 8192];
    for turn in 4096 {
        if sent < total {
            let written = send_remaining(pair.writer, head, body, sent);
            assert(written.status == silly_transport::IoStatus.Ready
                || written.status == silly_transport::IoStatus.WouldBlock);
            sent += written.count;
        }
        let read = silly_transport::read(pair.reader, buffer);
        assert(read.status == silly_transport::IoStatus.Ready
            || read.status == silly_transport::IoStatus.WouldBlock);
        if read.status == silly_transport::IoStatus.Ready {
            received.append(buffer[..read.count]);
        }
        if received.len == total {
            assert(sent == total);
            assert(received[..head.len] == head);
            assert(received[head.len..] == body);
            return;
        }
    }
    abort("partial write did not finish within the bounded turn count");
}

fn pressure() {
    var pair = silly_transport::wake_pair(4096);
    assert(pair.status == silly_transport::IoStatus.Ready);
    var body: u8[>..] = [];
    for index in 1024 * 1024 {
        body.push((index % 251)as u8);
    }
    let head = "header bytes\r\n\r\n";
    let sent = fill_pressure(pair.writer, head, body);
    resume_pressure(pair, head, body, sent);
    close_pair(pair);
    // Also force the partial write inside the first vector, then cross into the second.
    var second = silly_transport::wake_pair(4096);
    assert(second.status == silly_transport::IoStatus.Ready);
    let header_sent = fill_pressure(second.writer, body, "tail");
    assert(header_sent < body.len);
    resume_pressure(second, body, "tail", header_sent);
    close_pair(second);
}

fn eof_and_poll_errors() {
    var pair = silly_transport::wake_pair();
    assert(pair.status == silly_transport::IoStatus.Ready);
    assert(silly_transport::close(pair.writer).status == silly_transport::IoStatus.Ready);
    var bytes: u8[1] = [0];
    assert(silly_transport::read(pair.reader, bytes).status == silly_transport::IoStatus.Closed);
    assert(silly_transport::close(pair.reader).status == silly_transport::IoStatus.Ready);
    var events: i32[1] = [0];
    assert(silly_transport::poll([-1], [silly_transport::READ], events, 0).count == 0);
    assert(silly_transport::poll([-1], [16], events, 0).status == silly_transport::IoStatus.Invalid);
    assert(silly_transport::poll([-1], [1], events, -1).status == silly_transport::IoStatus.Invalid);
    let interrupted = silly_transport::decoded(silly_test_interrupt_poll());
    assert(interrupted.status == silly_transport::IoStatus.Interrupted);
    assert(interrupted.error != 0);
}

fn peer_reset() {
    var listener = silly_transport::listen("127.0.0.1", 0, 8);
    assert(listener.status == silly_transport::IoStatus.Ready);
    let port = silly_transport::local_port(listener.descriptor);
    assert(port.status == silly_transport::IoStatus.Ready);
    var client = silly_transport::connect("127.0.0.1", port.count as i32);
    assert(client.status == silly_transport::IoStatus.Ready
        || client.status == silly_transport::IoStatus.WouldBlock);
    var events: i32[1] = [0];
    let ready = silly_transport::poll([client.descriptor.fd], [silly_transport::WRITE], events, 1000);
    assert(ready.status == silly_transport::IoStatus.Ready);
    assert(ready.count == 1);
    assert(silly_transport::finish_connect(client.descriptor).status == silly_transport::IoStatus.Ready);
    var accepted = silly_transport::accept(listener.descriptor);
    assert(accepted.status == silly_transport::IoStatus.Ready);
    assert(silly_test_reset_on_close(accepted.descriptor.fd) == 0);
    assert(silly_transport::close(accepted.descriptor).status == silly_transport::IoStatus.Ready);
    let reset_ready = silly_transport::poll([client.descriptor.fd], [silly_transport::READ], events, 1000);
    assert(reset_ready.status == silly_transport::IoStatus.Ready);
    assert(reset_ready.count == 1);
    var output: u8[8] = [0; 8];
    let read = silly_transport::read(client.descriptor, output);
    assert(read.status == silly_transport::IoStatus.Closed);
    assert(read.error != 0);
    assert(silly_transport::close(client.descriptor).status == silly_transport::IoStatus.Ready);
    assert(silly_transport::close(listener.descriptor).status == silly_transport::IoStatus.Ready);
}

fn clock_and_listener() {
    let before = silly_transport::monotonic_ms();
    assert(before.status == silly_transport::IoStatus.Ready);
    let after = silly_transport::monotonic_ms();
    assert(after.status == silly_transport::IoStatus.Ready);
    assert(after.count >= before.count);
    assert(silly_transport::listen("invalid", 0, 8).status == silly_transport::IoStatus.Invalid);
    var listener = silly_transport::listen("127.0.0.1", 0, 8);
    assert(listener.status == silly_transport::IoStatus.Ready);
    let port = silly_transport::local_port(listener.descriptor);
    assert(port.status == silly_transport::IoStatus.Ready);
    assert(port.count > 0);
    assert(silly_transport::accept(listener.descriptor).status == silly_transport::IoStatus.WouldBlock);
    assert(silly_transport::close(listener.descriptor).status == silly_transport::IoStatus.Ready);
}

fn::main() {
    transport_test::wake_and_close();
    transport_test::pressure();
    transport_test::eof_and_poll_errors();
    transport_test::clock_and_listener();
    transport_test::peer_reset();
    print("native transport contracts passed");
}
