// Incremental HTTP head scanner. Errors are sticky; only complete validated heads expose views.
namespace silly;

import.http_head_types;
import.http_headers;
import.http_request_line;

fn scan_head(scan: HeadScan&, input: u8[:], limits: Limits) -> HeadResult {
    if scan.result != HeadResult.NeedMore {
        return scan.result;
    }
    if !valid(limits) || scan.checked_bytes > input.len {
        scan.result = HeadResult.BadRequest;
        return scan.result;
    }
    while scan.checked_bytes < input.len {
        scan.result = scan_head_byte(scan, input, limits);
        if scan.result != HeadResult.NeedMore {
            return scan.result;
        }
    }
    if scan.checked_bytes == limits.head_bytes_max {
        scan.result = HeadResult.HeadLimit;
    }
    return scan.result;
}

// E1 compatibility overload; new callers supply all named limits.
fn scan_head(scan: HeadScan&, input: u8[:], limit: i64) -> HeadResult {
    return scan_head(scan, input, Limits {
            head_bytes_max: limit,
            ..
        });
}

fn scan_head_byte(scan: HeadScan&, input: u8[:], limits: Limits) -> HeadResult {
    let index = scan.checked_bytes;
    let line_bytes = index - scan.line_start + 1;
    if index >= limits.head_bytes_max {
        return HeadResult.HeadLimit;
    }
    if scan.request_line_end < 0 && line_bytes > limits.request_line_bytes_max {
        return HeadResult.RequestLineLimit;
    }
    if scan.request_line_end >= 0 && (line_bytes > limits.header_line_bytes_max
        || index - scan.header_section_start + 1 > limits.header_section_bytes_max) {
        return HeadResult.HeaderLimit;
    }
    let byte = input[index];
    scan.checked_bytes += 1;
    if scan.pending_cr {
        scan.pending_cr = false;
        if byte != '\n' {
            return HeadResult.BadRequest;
        }
        return finish_head_line(scan, input, limits);
    }
    if byte == '\r' {
        scan.pending_cr = true;
    } else if byte == '\n' || byte == 127 || (byte < 32 && byte != '\t') {
        return HeadResult.BadRequest;
    }
    return HeadResult.NeedMore;
}

fn finish_head_line(scan: HeadScan&, input: u8[:], limits: Limits) -> HeadResult {
    let end = scan.checked_bytes - 2;
    if scan.request_line_end < 0 {
        let line = parse_request_line(input[..end]);
        if line.result != HeadResult.Complete {
            return line.result;
        }
        scan.request_line_end = end;
        scan.header_section_start = scan.checked_bytes;
    } else if end == scan.line_start {
        scan.head_bytes = scan.checked_bytes;
        return HeadResult.Complete;
    } else {
        scan.field_count += 1;
        if scan.field_count > limits.header_count_max {
            return HeadResult.HeaderLimit;
        }
        let line = input[scan.line_start..end];
        let colon = head_byte_index(line, ':', 0);
        if colon <= 0 || !valid_header_name(line[..colon]) || !valid_header_value(line[colon + 1..]) {
            return HeadResult.BadRequest;
        }
    }
    scan.line_start = scan.checked_bytes;
    return HeadResult.NeedMore;
}

// Bytes after head_bytes are untouched and remain available to the next protocol stage.
fn parse_head(input: u8[:], fields: HeaderView[>..]&, limits: Limits) -> ParsedHead {
    var index: HeaderIndexEntry[>..] = [];
    return parse_head(input, fields, index, limits);
}

// Both output owners must be empty; the index borrows no bytes and retains source offsets.
fn parse_head(input: u8[:], fields: HeaderView[>..]&, index: HeaderIndexEntry[>..]&, limits: Limits) -> ParsedHead {
    if fields.len != 0 || index.len != 0 {
        return ParsedHead {
        };
    }
    var scan = HeadScan {
    };
    let result = scan_head(scan, input, limits);
    if result != HeadResult.Complete {
        return ParsedHead {
            result: result,
            ..
        };
    }
    var parsed = parse_request_line(input[..scan.request_line_end]);
    let headers = collect_head_fields(input[..scan.head_bytes], scan.header_section_start, fields, index, limits);
    if headers != HeadResult.Complete {
        fields.clear();
        index.clear();
        return ParsedHead {
            result: headers,
            ..
        };
    }
    let framing = validate_head_fields(fields, parsed.http_minor);
    if framing.result != HeadResult.Complete {
        fields.clear();
        index.clear();
        return ParsedHead {
            result: framing.result,
            ..
        };
    }
    parsed.head_bytes = scan.head_bytes;
    parsed.framing = framing.kind;
    parsed.content_length = framing.content_length;
    return parsed;
}

fn collect_head_fields(input: u8[:], start: i64, fields: HeaderView[>..]&, index: HeaderIndexEntry[>..]&,
    limits: Limits) -> HeadResult {
    var cursor = start;
    var remaining = limits.header_bytes_max;
    while cursor < input.len - 2 {
        let end = head_line_end(input, cursor);
        let line = input[cursor..end];
        let colon = head_byte_index(line, ':', 0);
        if line.len - 1 > remaining {
            return HeadResult.HeaderLimit;
        }
        remaining -= line.len - 1;
        fields.push(HeaderView {
                name: line[..colon],
                value: line[colon + 1..]
            });
        index_header(index, fields, fields.len - 1, HeaderField {
                name_start: cursor,
                name_bytes: colon,
                value_start: cursor + colon + 1,
                value_bytes: end - cursor - colon - 1,
            });
        cursor = end + 2;
    }
    return HeadResult.Complete;
}

// Legacy exact-head/bodyless-GET adapter. Production head parsing uses parse_head directly.
fn parse_get_head(input: u8[:], fields: HeaderView[>..]&, limits: Limits) -> ParsedHead {
    var parsed = parse_head(input, fields, limits);
    if parsed.result == HeadResult.NeedMore || parsed.result == HeadResult.Truncated {
        parsed.result = HeadResult.BadRequest;
    }
    if parsed.result != HeadResult.Complete {
        return parsed;
    }
    if parsed.head_bytes != input.len {
        parsed.result = HeadResult.BadRequest;
    } else if parsed.method != "GET" {
        parsed.result = HeadResult.UnsupportedMethod;
    } else if parsed.framing == BodyFraming.Chunked || parsed.content_length != 0
        || find_header(fields, "Expect") >= 0 {
        parsed.result = HeadResult.UnsupportedBody;
    }
    return parsed;
}

fn head_line_end(input: u8[:], start: i64) -> i64 {
    for index in start..input.len {
        if input[index] == '\n' {
            return index - 1;
        }
    }
    return -1;
}
