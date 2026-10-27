// Bounded UTF-8 SSE blocks. Preflight validates every byte and capacity before output mutation.
namespace silly;

import std;

import.stream_contract;
import.utf8;

struct SseEvent {
    data: const u8[:] = "",
    event: const u8[:] = "",
    id: const u8[:] = "",
    retry_ms: i64 = -1,
    data_present: bool = true,
    id_present: bool = false,
}

fn sse_event(out: ChunkWriter&, event: SseEvent) -> bool {
    if !sse_writer_valid(out) || !sse_single_line(event.event) || !sse_single_line(event.id)
        || !valid_utf8(event.data) || event.retry_ms < - 1 {
        return false;
    }
    let retry: u8[>..] = if event.retry_ms >= 0 {
        str(event.retry_ms)
    } else {
        ""
    };
    var remaining = out.bytes.len - out.used;
    if !sse_event_fits(event, retry, remaining) {
        return false;
    }
    if event.event.len > 0 {
        sse_line(out, "event: ", event.event);
    }
    if event.id_present || event.id.len > 0 {
        sse_line(out, "id: ", event.id);
    }
    if event.retry_ms >= 0 {
        sse_line(out, "retry: ", retry);
    }
    if event.data_present {
        sse_lines(out, "data: ", event.data);
    }
    append(out, "\n");
    return true;
}

fn sse_comment(out: ChunkWriter&, comment: u8[:]) -> bool {
    if !sse_writer_valid(out) || !valid_utf8(comment) {
        return false;
    }
    var remaining = out.bytes.len - out.used;
    if !sse_lines_fit(remaining, 2, comment) || !sse_take(remaining, 1) {
        return false;
    }
    sse_lines(out, ": ", comment);
    append(out, "\n");
    return true;
}

fn sse_writer_valid(out: ChunkWriter&) -> bool {
    return out.used >= 0 && out.used <= out.bytes.len;
}

// NUL in event names is rejected as well as the required ID restriction.
fn sse_single_line(value: u8[:]) -> bool {
    if !valid_utf8(value) {
        return false;
    }
    for byte in value {
        if byte == '\r' || byte == '\n' || byte == 0 {
            return false;
        }
    }
    return true;
}

fn sse_event_fits(event: SseEvent, retry: u8[:], remaining: i64&) -> bool {
    if event.event.len > 0 && !sse_line_fits(remaining, 7, event.event.len) {
        return false;
    }
    if (event.id_present || event.id.len > 0) && !sse_line_fits(remaining, 4, event.id.len) {
        return false;
    }
    if event.retry_ms >= 0 && !sse_line_fits(remaining, 7, retry.len) {
        return false;
    }
    if event.data_present && !sse_lines_fit(remaining, 6, event.data) {
        return false;
    }
    return sse_take(remaining, 1);
}

fn sse_take(remaining: i64&, size: i64) -> bool {
    if size > remaining {
        return false;
    }
    remaining -= size;
    return true;
}

fn sse_line_fits(remaining: i64&, prefix: i64, bytes: i64) -> bool {
    return sse_take(remaining, prefix) && sse_take(remaining, bytes) && sse_take(remaining, 1);
}

fn sse_lines_fit(remaining: i64&, prefix: i64, text: u8[:]) -> bool {
    var start: i64 = 0;
    var end: i64 = 0;
    while end < text.len {
        if text[end] != '\r' && text[end] != '\n' {
            end += 1;
            continue;
        }
        if !sse_line_fits(remaining, prefix, end - start) {
            return false;
        }
        if text[end] == '\r' && end + 1 < text.len && text[end + 1] == '\n' {
            end += 1;
        }
        end += 1;
        start = end;
    }
    return sse_line_fits(remaining, prefix, text.len - start);
}

fn sse_line(out: ChunkWriter&, prefix: u8[:], text: u8[:]) {
    append(out, prefix);
    append(out, text);
    append(out, "\n");
}

fn sse_lines(out: ChunkWriter&, prefix: u8[:], text: u8[:]) {
    var start: i64 = 0;
    var end: i64 = 0;
    while end < text.len {
        if text[end] != '\r' && text[end] != '\n' {
            end += 1;
            continue;
        }
        sse_line(out, prefix, text[start..end]);
        if text[end] == '\r' && end + 1 < text.len && text[end + 1] == '\n' {
            end += 1;
        }
        end += 1;
        start = end;
    }
    sse_line(out, prefix, text[start..]);
}
