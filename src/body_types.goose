// Fixed-size request-body state; no input/output address survives a read operation.
namespace silly;

import.http_head_types;

struct BodyLimits {
    bytes_max: i64 = 8 * 1024 * 1024,
    overhead_bytes_max: i64 = 1024 * 1024,
    line_bytes_max: i64 = 8192,
    trailer_bytes_max: i64 = 16384,
    trailer_count_max: i64 = 100,
    chunk_count_max: i64 = 65536,
}

enum BodyStatus {
    NeedInput,
    NeedOutput,
    Progress,
    Complete,
    BadFraming,
    Truncated,
    Limit,
    OverheadLimit,
    InvalidLimits,
}

enum BodyPhase {
    Size,
    Data,
    DataCR,
    DataLF,
    Trailer,
    Done,
}

struct BodyReader {
    framing: BodyFraming = BodyFraming.None,
    limits: BodyLimits = BodyLimits {
    },
    status: BodyStatus = BodyStatus.Complete,
    phase: BodyPhase = BodyPhase.Done,
    decoded_bytes: i64 = 0,
    remaining: i64 = 0,
    overhead_bytes: i64 = 0,
    trailer_bytes: i64 = 0,
    trailer_count: i64 = 0,
    chunk_count: i64 = 0,
    line_bytes: i64 = 0,
    pending_cr: bool = false,
    line: u8[..8192] = [],
}

struct BodyRead {
    consumed: i64 = 0,
    produced: i64 = 0,
    status: BodyStatus = BodyStatus.NeedInput,
}

fn valid_body_limits(limits: BodyLimits) -> bool {
    return limits.bytes_max >= 0 && limits.overhead_bytes_max >= 0
        && limits.line_bytes_max > 0 && limits.line_bytes_max <= 8192
        && limits.trailer_bytes_max >= 0 && limits.trailer_count_max >= 0
        && limits.chunk_count_max >= 0;
}

fn body_terminal(status: BodyStatus) -> bool {
    return status != BodyStatus.NeedInput && status != BodyStatus.NeedOutput && status != BodyStatus.Progress;
}

fn body_status_code(status: BodyStatus) -> i32 {
    var code: i32 = 400;
    if status == BodyStatus.Limit || status == BodyStatus.OverheadLimit {
        code = 413;
    } else if status == BodyStatus.InvalidLimits {
        code = 500;
    } else if !body_terminal(status) || status == BodyStatus.Complete {
        code = 0;
    }
    return code;
}
