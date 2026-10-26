// Compiler-proven synchronous step vocabulary; scheduling and HTTP streaming follow in E7.
namespace silly;

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

struct ChunkWriter {
    bytes: u8[:],
    used: i64 = 0,
}

// A driver-local sink. S must be fixed, owned state; the compiler rejects escaping local roots.
struct StreamStart<S> {
    selected: bool = false,
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
        _ => {
            return true;
        },
    }
}
