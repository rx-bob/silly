// Buffered response head serialization. Payload remains in its original response owner.
namespace silly;

import std;

import.headers;
import.response;

// No output mutation or commitment occurs on failure. Caller commits only after success.
fn write_response_head(out: u8[>..]&, response: Response&, http_minor: i32, cap: i64) -> ResponseError {
    if response.mode != ResponseBodyMode.Buffered {
        return ResponseError.InvalidState;
    }
    if response.phase != ResponsePhase.Prepared || out.len != 0 || (http_minor != 0 && http_minor != 1) {
        return ResponseError.InvalidState;
    }
    if cap < 0 {
        return ResponseError.InvalidLimits;
    }
    if response.status < 200 || response.status > 599 {
        return ResponseError.InvalidStatus;
    }
    let no_body = response.status == 204 || response.status == 304;
    if (no_body || response.status == 205) && response.output.len != 0 {
        return ResponseError.InvalidState;
    }
    let prefix = str("HTTP/1.", http_minor, " ", response.status, " ", response_reason(response.status), "\r\n");
    let framing = if no_body {
        str("Connection: close\r\n")
    } else {
        str("Content-Length: ", response.output.len, "\r\nConnection: close\r\n")
    };
    if prefix.len > cap || framing.len > cap - prefix.len || 2 > cap - prefix.len - framing.len {
        return ResponseError.HeaderBytesLimit;
    }
    let result = response_field_size(response, cap - prefix.len - framing.len - 2);
    if result != ResponseError.None {
        return result;
    }
    out.append(prefix);
    out.append(framing);
    for index in response.header_fields.len {
        let field = header_view(response.header_fields, response.header_bytes, index);
        out.append(field.name);
        out.append(": ");
        out.append(field.value);
        out.append("\r\n");
    }
    out.append("\r\n");
    return ResponseError.None;
}

fn response_field_size(response: Response&, capacity: i64) -> ResponseError {
    var remaining = capacity;
    for index in response.header_fields.len {
        let field = header_view(response.header_fields, response.header_bytes, index);
        if !valid_header_name(field.name) || !valid_header_value(field.value) || reserved_framing(field.name) {
            return ResponseError.InvalidHeader;
        }
        if field.name.len > remaining {
            return ResponseError.HeaderBytesLimit;
        }
        remaining -= field.name.len;
        if field.value.len > remaining {
            return ResponseError.HeaderBytesLimit;
        }
        remaining -= field.value.len;
        if remaining < 4 {
            return ResponseError.HeaderBytesLimit;
        }
        remaining -= 4;
    }
    return ResponseError.None;
}

fn reserved_framing(name: u8[:]) -> bool {
    return header_name_equal(name, "Content-Length")
        || header_name_equal(name, "Transfer-Encoding")
        || header_name_equal(name, "Connection")
        || header_name_equal(name, "Trailer")
        || header_name_equal(name, "Upgrade");
}

fn response_reason(status: i32) -> const u8[:] {
    if status == 200 {
        return "OK";
    }
    if status == 204 {
        return "No Content";
    }
    if status == 400 {
        return "Bad Request";
    }
    if status == 404 {
        return "Not Found";
    }
    if status == 405 {
        return "Method Not Allowed";
    }
    if status == 431 {
        return "Request Header Fields Too Large";
    }
    if status == 413 {
        return "Content Too Large";
    }
    if status == 417 {
        return "Expectation Failed";
    }
    if status == 414 {
        return "URI Too Long";
    }
    if status == 505 {
        return "HTTP Version Not Supported";
    }
    if status == 500 {
        return "Internal Server Error";
    }
    if status == 501 {
        return "Not Implemented";
    }
    if status == 503 {
        return "Service Unavailable";
    }
    return "Response";
}
