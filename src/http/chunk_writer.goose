// Chunk framing bytes have their own owner; payload bytes are never concatenated here.
namespace silly;

import std;

fn write_chunk_prefix(out: u8[>..]&, length: i64, cap: i64) -> ResponseError {
    if cap < 0 {
        return ResponseError.InvalidLimits;
    }
    if out.len != 0 || length <= 0 {
        return ResponseError.InvalidState;
    }
    var bytes: u8[18] = [0; 18];
    bytes[16] = '\r';
    bytes[17] = '\n';
    var start: i64 = 16;
    var remaining = length;
    let digits = "0123456789abcdef";
    while remaining > 0 {
        start -= 1;
        bytes[start] = digits[remaining % 16];
        remaining /= 16;
    }
    if bytes.len - start > cap {
        return ResponseError.HeaderBytesLimit;
    }
    out.append(bytes[start..]);
    return ResponseError.None;
}

// An empty data chunk is not a terminator; ending the stream is a separate explicit operation.
fn write_chunk_end(out: u8[>..]&, cap: i64) -> ResponseError {
    if cap < 0 {
        return ResponseError.InvalidLimits;
    }
    if out.len != 0 {
        return ResponseError.InvalidState;
    }
    if cap < 5 {
        return ResponseError.HeaderBytesLimit;
    }
    out.append("0\r\n\r\n");
    return ResponseError.None;
}
