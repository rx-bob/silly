// Atomic bounded HTTP heads; body bytes remain in separate driver-owned segments.
namespace silly;

import std;

import.headers;
import.response;
import.response_wire_plan;
import.response_wire_types;

// Compatibility entry point for buffered GET responses; new callers retain the wire plan.
fn write_response_head(out: u8[>..]&, response: Response&, http_minor: i32, cap: i64) -> ResponseError {
    if response.mode != ResponseBodyMode.Buffered {
        return ResponseError.InvalidState;
    }
    return prepare_response_head(out, response, ResponseWireOptions {
            http_minor: http_minor,
            ..
        }, cap).error;
}

// All capacity/metadata checks precede writes. This never commits the response.
fn prepare_response_head(out: u8[>..]&, response: Response&,
    options: ResponseWireOptions, cap: i64) -> ResponseWirePlan {
    var plan = plan_response_wire(response, options);
    if plan.error != ResponseError.None {
        return plan;
    }
    if out.len != 0 || cap < 0 {
        plan.error = if cap < 0 {
            ResponseError.InvalidLimits
        } else {
            ResponseError.InvalidState
        };
        return plan;
    }
    let reason = response_reason(response.status);
    let prefix = str("HTTP/1.", options.http_minor, " ", response.status, " ", reason, "\r\n");
    let framing = response_framing_lines(plan, options.http_minor);
    if prefix.len > cap || framing.len > cap - prefix.len || 2 > cap - prefix.len - framing.len {
        plan.error = ResponseError.HeaderBytesLimit;
    } else {
        plan.error = response_field_size(response, cap - prefix.len - framing.len - 2);
    }
    if plan.error == ResponseError.None {
        out.append(prefix);
        out.append(framing);
        append_response_fields(out, response);
        out.append("\r\n");
    }
    return plan;
}

fn response_framing_lines(plan: ResponseWirePlan, http_minor: i32) -> u8[>..] {
    var lines: u8[>..] = [];
    if plan.content_length >= 0 {
        lines.append(str("Content-Length: ", plan.content_length, "\r\n"));
    } else if plan.framing == ResponseFraming.Chunked {
        lines.append("Transfer-Encoding: chunked\r\n");
    }
    if plan.close {
        lines.append("Connection: close\r\n");
    } else if http_minor == 0 {
        lines.append("Connection: keep-alive\r\n");
    }
    return lines;
}

fn append_response_fields(out: u8[>..]&, response: Response&) {
    for index in response.header_fields.len {
        let field = header_view(response.header_fields, response.header_bytes, index);
        append_wire_field(out, field);
    }
}

fn append_wire_field(out: u8[>..]&, field: HeaderView) {
    out.append(field.name);
    out.append(": ");
    out.append(field.value);
    out.append("\r\n");
}

fn response_field_size(response: Response&, capacity: i64) -> ResponseError {
    if response.header_fields.len > response.limits.header_count_max {
        return ResponseError.HeaderCountLimit;
    }
    if response.header_bytes.len > response.limits.header_bytes_max {
        return ResponseError.HeaderBytesLimit;
    }
    var remaining = capacity;
    for index in response.header_fields.len {
        if !valid_response_offsets(response.header_fields[index], response.header_bytes.len) {
            return ResponseError.InvalidHeader;
        }
        let field = header_view(response.header_fields, response.header_bytes, index);
        let error = wire_field_size(field, remaining);
        if error != ResponseError.None {
            return error;
        }
        remaining -= field.name.len + field.value.len + 4;
    }
    return ResponseError.None;
}

fn valid_response_offsets(field: HeaderField, length: i64) -> bool {
    return field.name_start >= 0 && field.name_bytes >= 0 && field.name_start <= length
        && field.name_bytes <= length - field.name_start && field.value_start >= 0
        && field.value_bytes >= 0 && field.value_start <= length
        && field.value_bytes <= length - field.value_start;
}

fn wire_field_size(field: HeaderView, capacity: i64) -> ResponseError {
    if field.name.len > capacity || field.value.len > capacity - field.name.len
        || 4 > capacity - field.name.len - field.value.len {
        return ResponseError.HeaderBytesLimit;
    }
    if !valid_header_name(field.name) || !valid_header_value(field.value) || reserved_framing(field.name) {
        return ResponseError.InvalidHeader;
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

// Interim messages have no content/framing fields and do not replace the final response.
fn write_informational_head(out: u8[>..]&, status: i32, fields: HeaderView[:],
    http_minor: i32, cap: i64) -> ResponseError {
    if out.len != 0 || http_minor != 1 {
        return ResponseError.InvalidState;
    }
    if status < 100 || status > 199 || status == 101 {
        return ResponseError.InvalidStatus;
    }
    if cap < 0 {
        return ResponseError.InvalidLimits;
    }
    let prefix = str("HTTP/1.1 ", status, " ", response_reason(status), "\r\n");
    if prefix.len > cap || 2 > cap - prefix.len {
        return ResponseError.HeaderBytesLimit;
    }
    var remaining = cap - prefix.len - 2;
    for field in fields {
        let error = wire_field_size(field, remaining);
        if error != ResponseError.None {
            return error;
        }
        remaining -= field.name.len + field.value.len + 4;
    }
    out.append(prefix);
    for field in fields {
        append_wire_field(out, field);
    }
    out.append("\r\n");
    return ResponseError.None;
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
    if status == 408 {
        return "Request Timeout";
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
    return response_extra_reason(status);
}

fn response_extra_reason(status: i32) -> const u8[:] {
    if status == 100 {
        return "Continue";
    }
    if status == 102 {
        return "Processing";
    }
    if status == 103 {
        return "Early Hints";
    }
    if status == 201 {
        return "Created";
    }
    if status == 202 {
        return "Accepted";
    }
    if status == 205 {
        return "Reset Content";
    }
    if status == 206 {
        return "Partial Content";
    }
    if status == 301 {
        return "Moved Permanently";
    }
    if status == 302 {
        return "Found";
    }
    if status == 303 {
        return "See Other";
    }
    if status == 304 {
        return "Not Modified";
    }
    if status == 307 {
        return "Temporary Redirect";
    }
    if status == 308 {
        return "Permanent Redirect";
    }
    return "Response";
}
