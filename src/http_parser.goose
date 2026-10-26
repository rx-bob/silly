// Initial bounded GET head parser. E2 extends framing, methods and connection persistence.
namespace silly;

import std;

import.headers;
import.limits;

enum HeadResult {
    NeedMore,
    Complete,
    BadRequest,
    HeadLimit,
    HeaderLimit,
    UnsupportedMethod,
    UnsupportedBody,
    UnsupportedVersion,
}

struct HeadScan {
    checked_bytes: i64 = 0,
    head_bytes: i64 = 0,
}

struct ParsedHead {
    result: HeadResult = HeadResult.BadRequest,
    target: const u8[:] = "",
    http_minor: i32 = 1,
}

// Each appended byte is examined at most four times. Reset the state with its input owner.
fn scan_head(scan: HeadScan&, input: u8[:], limit: i64) -> HeadResult {
    if limit <= 0 || input.len > limit {
        return HeadResult.HeadLimit;
    }
    if scan.checked_bytes > input.len {
        return HeadResult.BadRequest;
    }
    if scan.head_bytes > 0 {
        return HeadResult.Complete;
    }
    var index = max(0, scan.checked_bytes - 3);
    while index <= input.len - 4 {
        if input[index] == '\r' && input[index + 1] == '\n'
            && input[index + 2] == '\r' && input[index + 3] == '\n' {
            scan.head_bytes = index + 4;
            return HeadResult.Complete;
        }
        index += 1;
    }
    scan.checked_bytes = input.len;
    if input.len == limit {
        return HeadResult.HeadLimit;
    }
    return HeadResult.NeedMore;
}

// Input must be exactly the complete head. Header views borrow input and preserve wire order.
// On failure the caller discards fields; no handler may inspect the partial parse.
fn parse_get_head(input: u8[:], fields: HeaderView[>..]&, limits: Limits) -> ParsedHead {
    if !valid(limits) || input.len > limits.head_bytes_max {
        return ParsedHead {
            result: HeadResult.HeadLimit,
            ..
        };
    }
    if fields.len != 0 {
        return ParsedHead {
        };
    }
    let line_end = head_line_end(input, 0);
    if line_end < 0 {
        return ParsedHead {
        };
    }
    let parsed = parse_get_line(input[..line_end]);
    if parsed.result != HeadResult.Complete {
        return parsed;
    }
    let result = parse_head_fields(input, line_end + 2, fields, limits);
    if result != HeadResult.Complete {
        return ParsedHead {
            result: result,
            ..
        };
    }
    let policy = validate_get_fields(fields, parsed.http_minor);
    if policy != HeadResult.Complete {
        return ParsedHead {
            result: policy,
            ..
        };
    }
    return parsed;
}

fn parse_get_line(line: u8[:]) -> ParsedHead {
    let method_end = head_byte_index(line, ' ', 0);
    if method_end <= 0 || !valid_header_name(line[..method_end]) {
        return ParsedHead {
        };
    }
    if line[..method_end] != "GET" {
        return ParsedHead {
            result: HeadResult.UnsupportedMethod,
            ..
        };
    }
    let target_end = head_byte_index(line, ' ', method_end + 1);
    if target_end <= method_end + 1 {
        return ParsedHead {
        };
    }
    let target = line[method_end + 1..target_end];
    if target[0] != '/' {
        return ParsedHead {
        };
    }
    for byte in target {
        if byte <= 32 || byte == 127 || byte == '#' {
            return ParsedHead {
            };
        }
    }
    let version = line[target_end + 1..];
    if version != "HTTP/1.0" && version != "HTTP/1.1" {
        return ParsedHead {
            result: HeadResult.UnsupportedVersion,
            ..
        };
    }
    return ParsedHead {
        result: HeadResult.Complete,
        target: target,
        http_minor: if version == "HTTP/1.0" {
            0
        } else {
            1
        },
    };
}

fn parse_head_fields(input: u8[:], start: i64, fields: HeaderView[>..]&, limits: Limits) -> HeadResult {
    var cursor = start;
    var remaining = limits.header_bytes_max;
    while cursor < input.len {
        let end = head_line_end(input, cursor);
        if end < 0 {
            return HeadResult.BadRequest;
        }
        if end == cursor {
            return if end + 2 == input.len {
                HeadResult.Complete
            } else {
                HeadResult.BadRequest
            };
        }
        let line = input[cursor..end];
        let colon = head_byte_index(line, ':', 0);
        if colon <= 0 || !valid_header_name(line[..colon]) || !valid_header_value(line[colon + 1..]) {
            return HeadResult.BadRequest;
        }
        if fields.len >= limits.header_count_max || line.len - 1 > remaining {
            return HeadResult.HeaderLimit;
        }
        remaining -= line.len - 1;
        fields.push(HeaderView {
                name: line[..colon],
                value: line[colon + 1..]
            });
        cursor = end + 2;
    }
    return HeadResult.BadRequest;
}

fn validate_get_fields(fields: HeaderView[:], http_minor: i32) -> HeadResult {
    var hosts = 0;
    var lengths = 0;
    for field in fields {
        if header_name_equal(field.name, "Host") {
            hosts += 1;
            if hosts > 1 || trim_head_space(field.value).len == 0 {
                return HeadResult.BadRequest;
            }
        }
        if header_name_equal(field.name, "Transfer-Encoding") || header_name_equal(field.name, "Expect") {
            return HeadResult.UnsupportedBody;
        }
        if header_name_equal(field.name, "Content-Length") {
            lengths += 1;
            if lengths > 1 {
                return HeadResult.BadRequest;
            }
            let length = trim_head_space(field.value);
            if length.len == 0 {
                return HeadResult.BadRequest;
            }
            for byte in length {
                if byte < '0' || byte > '9' {
                    return HeadResult.BadRequest;
                }
                if byte != '0' {
                    return HeadResult.UnsupportedBody;
                }
            }
        }
    }
    if http_minor == 1 && hosts != 1 {
        return HeadResult.BadRequest;
    }
    return HeadResult.Complete;
}

fn trim_head_space(value: u8[:]) -> const u8[:] {
    var start = 0;
    var end = value.len;
    while start < end && (value[start] == ' ' || value[start] == '\t') {
        start += 1;
    }
    while end > start && (value[end - 1] == ' ' || value[end - 1] == '\t') {
        end -= 1;
    }
    return value[start..end];
}

fn head_line_end(input: u8[:], start: i64) -> i64 {
    for index in start..input.len {
        if input[index] == '\n' {
            if index > start && input[index - 1] == '\r' {
                return index - 1;
            }
            return -1;
        }
        if input[index] == '\r' && index + 1 < input.len && input[index + 1] != '\n' {
            return -1;
        }
    }
    return -1;
}

fn head_byte_index(input: u8[:], byte: u8, start: i64) -> i64 {
    for index in start..input.len {
        if input[index] == byte {
            return index;
        }
    }
    return -1;
}
