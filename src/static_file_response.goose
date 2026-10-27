// Static responses retain bounded conditional fields until descriptor metadata is ready.
namespace silly;

import std;

import.context;
import.file_conditions;
import.file_response;
import.file_transfer;
import.file_transfer_types;
import.file_types;
import.headers;
import.request;
import.request_headers;
import.response;
import.static_file_ranges;

struct StaticFileOptions {
    content_type: const u8[:] = "",
    charset: const u8[:] = "utf-8",
    etag: const u8[:] = "",
    conditions: bool = true,
    ranges: bool = true,
    ranges_max: i64 = 16,
    pending_bytes_max: i64 = 4096,
    poll_interval_ms: i64 = 1,
}

fn static_file_response<A>(ctx: Context<A, FileTransfer> & , file: OwnedFile&, path: u8[:],
    options: StaticFileOptions = StaticFileOptions {
    }) -> ResponseError {
    if options.ranges_max < 1 || options.ranges_max > 16 {
        return ResponseError.InvalidLimits;
    }
    if options.etag.len > 256 || (options.etag.len != 0 && !valid_etag(options.etag)) {
        return ResponseError.InvalidHeader;
    }
    let mime = if options.content_type.len != 0 {
        options.content_type
    } else {
        static_mime(path)
    };
    let charset = if mime.len >= 5 && mime[..5] == "text/" {
        options.charset
    } else {
        ""
    };
    if mime.len > 512 || (charset.len > 0 && (mime.len > 502 || charset.len > 502 - mime.len)) {
        return ResponseError.HeaderBytesLimit;
    }
    let error = file_response(ctx, file, FileOptions {
            content_type: mime,
            charset: charset,
            pending_bytes_max: options.pending_bytes_max,
            poll_interval_ms: options.poll_interval_ms,
            ..
        });
    if error != ResponseError.None {
        return error;
    }
    let sink = ctx.stream_start;
    guard sink else {
        return ResponseError.InvalidState;
    }
    sink.defer_headers = true;
    sink.state.static_metadata = true;
    sink.state.configured_etag.append(options.etag);
    sink.state.conditional = options.conditions && (ctx.request.method == "GET" || ctx.request.method == "HEAD");
    capture_file_conditions(sink.state, ctx.request);
    sink.state.range_enabled = options.ranges;
    sink.state.ranges_max = options.ranges_max;
    sink.state.content_type.append(mime);
    if charset.len != 0 {
        sink.state.content_type.append(str("; charset=", charset));
    }
    capture_file_ranges(sink.state, ctx.request);
    return ResponseError.None;
}

fn capture_file_conditions(state: FileTransfer&, request: Request) {
    var values = header_values(request, "If-None-Match");
    while true {
        let value = next_header(values);
        if !value.present {
            break;
        }
        if state.none_match_present {
            if state.none_match.len == state.none_match.cap {
                state.none_match_valid = false;
            } else {
                state.none_match.push(',');
            }
        }
        state.none_match_present = true;
        if value.value.len > state.none_match.cap - state.none_match.len {
            state.none_match_valid = false;
        } else if state.none_match_valid {
            state.none_match.append(value.value);
        }
    }
    var dates = header_values(request, "If-Modified-Since");
    let first = next_header(dates);
    let second = next_header(dates);
    if first.present && !second.present && first.value.len <= state.modified_since.cap {
        state.modified_since.append(first.value);
    }
}

fn static_mime(path: u8[:]) -> const u8[:] {
    var dot: i64 = -1;
    for index in path.len {
        if path[index] == '/' {
            dot = -1;
        }
        if path[index] == '.' {
            dot = index;
        }
    }
    if dot >= 0 {
        let suffix = path[dot..];
        if header_name_equal(suffix, ".html") || header_name_equal(suffix, ".htm") {
            return "text/html";
        }
        if header_name_equal(suffix, ".mjs") || header_name_equal(suffix, ".js") {
            return "text/javascript";
        }
        if header_name_equal(suffix, ".css") {
            return "text/css";
        }
        if header_name_equal(suffix, ".txt") {
            return "text/plain";
        }
        if header_name_equal(suffix, ".wasm") {
            return "application/wasm";
        }
    }
    return "application/octet-stream";
}
