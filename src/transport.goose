// Canonical synchronous native boundary; descriptors own OS resources, never Goose pointers.
namespace silly_transport;

let READ = 1;
let WRITE = 2;
let CLOSED = 4;
let ERROR = 8;
let POLL_MAX = 1024;

struct Descriptor {
    fd: i32 = -1,
}

enum IoStatus {
    Ready,
    WouldBlock,
    Interrupted,
    Closed,
    Invalid,
    SystemError,
}

struct IoResult {
    status: IoStatus,
    count: i64 = 0,
    error: i32 = 0,
}

struct OpenResult {
    status: IoStatus,
    descriptor: Descriptor = Descriptor {
    },
    error: i32 = 0,
}

struct PairResult {
    status: IoStatus,
    reader: Descriptor = Descriptor {
    },
    writer: Descriptor = Descriptor {
    },
    error: i32 = 0,
}

extern fn silly_native_listen(address: const u8[:], port: i32, backlog: i32) -> i64;

extern fn silly_native_connect(address: const u8[:], port: i32) -> i64;

extern fn silly_native_finish_connect(fd: i32) -> i64;

extern fn silly_native_receive_buffer(fd: i32, bytes: i32) -> i64;

extern fn silly_native_accept(listener: i32) -> i64;

extern fn silly_native_close(fd: i32) -> i64;

// Writable output is intentional; goosefmt G015 currently flags all mutable FFI slices.
extern fn silly_native_read(fd: i32, output: u8[:]) -> i64;

extern fn silly_native_write(fd: i32, head: const u8[:], body: const u8[:]) -> i64;

// fds/interests are read-only; events is the synchronous result destination (G015 exception).
extern fn silly_native_poll(fds: const i32[:], interests: const i32[:], events: i32[:], timeout: i32) -> i64;

extern fn silly_native_clock() -> i64;

// Descriptor pair is copied into caller-owned output during this call (G015 exception).
extern fn silly_native_pair(output: i32[:], send_buffer: i32) -> i64;

extern fn silly_native_port(fd: i32) -> i64;

fn listen(address: u8[:], port: i32, backlog: i32) -> OpenResult {
    return opened(silly_native_listen(address, port, backlog));
}

// WouldBlock still transfers ownership of a connecting descriptor to the caller.
fn connect(address: u8[:], port: i32) -> OpenResult {
    let raw = silly_native_connect(address, port);
    if raw >= 4294967296 {
        return OpenResult {
            status: IoStatus.WouldBlock,
            descriptor: Descriptor {
                fd: (raw - 4294967296)as i32
            },
            ..
        };
    }
    return opened(raw);
}

// Call only after WRITE/ERROR/CLOSED readiness on the connecting descriptor.
fn finish_connect(descriptor: Descriptor) -> IoResult {
    return decoded(silly_native_finish_connect(descriptor.fd));
}

fn set_receive_buffer(descriptor: Descriptor, bytes: i32) -> IoResult {
    return decoded(silly_native_receive_buffer(descriptor.fd, bytes));
}

fn accept(listener: Descriptor) -> OpenResult {
    return opened(silly_native_accept(listener.fd));
}

// Invalidate before closing. Repeated closes never touch a reused numeric descriptor.
fn close(descriptor: Descriptor&) -> IoResult {
    if descriptor.fd < 0 {
        return IoResult {
            status: IoStatus.Closed
        };
    }
    let fd = descriptor.fd;
    descriptor.fd = -1;
    return decoded(silly_native_close(fd));
}

fn read(descriptor: Descriptor, output: u8[:]) -> IoResult {
    let raw = silly_native_read(descriptor.fd, output);
    if raw == 0 {
        return IoResult {
            status: IoStatus.Closed
        };
    }
    return decoded(raw);
}

// Exactly one sendmsg call. Caller owns slices and advances offsets only by returned count.
fn write_parts(descriptor: Descriptor, head: u8[:], body: u8[:]) -> IoResult {
    return decoded(silly_native_write(descriptor.fd, head, body));
}

fn poll(fds: i32[:], interests: i32[:], events: i32[:], timeout_ms: i32) -> IoResult {
    return decoded(silly_native_poll(fds, interests, events, timeout_ms));
}

fn monotonic_ms() -> IoResult {
    return decoded(silly_native_clock());
}

fn local_port(descriptor: Descriptor) -> IoResult {
    return decoded(silly_native_port(descriptor.fd));
}

fn wake_pair(send_buffer: i32 = 0) -> PairResult {
    var fds: i32[2] = [-1, -1];
    let result = decoded(silly_native_pair(fds, send_buffer));
    return PairResult {
        status: result.status,
        reader: Descriptor {
            fd: fds[0]
        },
        writer: Descriptor {
            fd: fds[1]
        },
        error: result.error,
    };
}

fn notify(descriptor: Descriptor) -> IoResult {
    return write_parts(descriptor, "", "x");
}

// Bounded drain: more than 256 pending wake bytes remain readable for the next turn.
fn drain_wake(descriptor: Descriptor) -> IoResult {
    var bytes: u8[256] = [0; 256];
    return read(descriptor, bytes);
}

fn opened(raw: i64) -> OpenResult {
    let result = decoded(raw);
    var descriptor = Descriptor {
    };
    if result.status == IoStatus.Ready {
        descriptor.fd = result.count as i32;
    }
    return OpenResult {
        status: result.status,
        descriptor: descriptor,
        error: result.error
    };
}

fn decoded(raw: i64) -> IoResult {
    if raw >= 0 {
        return IoResult {
            status: IoStatus.Ready,
            count: raw
        };
    }
    let code = -raw;
    let kind = code % 256;
    let status = match kind {
        1 => IoStatus.WouldBlock,
        2 => IoStatus.Interrupted,
        3 => IoStatus.Closed,
        4 => IoStatus.Invalid,
        _ => IoStatus.SystemError,
    };
    return IoResult {
        status: status,
        error: (code / 256)as i32
    };
}
