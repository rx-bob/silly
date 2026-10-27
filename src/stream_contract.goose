// Static producer callbacks borrow input and bounded output only for one step.
namespace silly;

import.stream_metadata_types;

enum StreamError {
    OutputLimit,
    Input,
    Transport,
    InvalidStep,
    Cancelled,
}

enum StreamEvent {
    Ready,
    Input {
        bytes: const u8[:]
    },
    InputEnd,
    InputFailed {
        reason: StreamError
    },
    Cancelled,
}

enum Wake {
    Ready,
    Input,
    InputAfter {
        delay_ms: i64
    },
    After {
        delay_ms: i64
    },
}

enum StreamStep {
    Chunk {
        flush: bool,
        next: Wake
    },
    Wait {
        wake: Wake
    },
    Done,
    Failed {
        reason: StreamError
    },
}

// A callback may select an owned replacement only before the first wire write.
struct StreamFailureResponse {
    selected: bool = false,
    status: i32 = 502,
    content_type: u8[..128] = [],
    body: u8[..4096] = [],
}

struct ChunkWriter {
    bytes: u8[:],
    used: i64 = 0,
    metadata: StreamMetadata? = null,
    failure: StreamFailureResponse? = null,
}

// A driver-local sink. S must be fixed, owned state; the compiler rejects escaping local roots.
struct StreamStart<S> {
    selected: bool = false,
    pending_bytes_max: i64 = 4096,
    input: bool = false,
    duplex: bool = false,
    defer_headers: bool = false,
    state: S = default<S>(),
}

fn append(out: ChunkWriter&, bytes: u8[:]) -> bool {
    if out.used < 0 || out.used > out.bytes.len || bytes.len > out.bytes.len - out.used {
        return false;
    }
    for index in bytes.len {
        out.bytes[out.used + index] = bytes[index];
    }
    out.used += bytes.len;
    return true;
}

fn valid_wake(wake: Wake) -> bool {
    match wake {
        After timer => {
            return timer.delay_ms >= 0;
        },
        InputAfter timer => {
            return timer.delay_ms >= 0;
        },
        _ => {
            return true;
        },
    }
}

fn input_wake(wake: Wake) -> bool {
    match wake {
        Input => {
            return true;
        },
        InputAfter _ => {
            return true;
        },
        _ => {
            return false;
        },
    }
}
