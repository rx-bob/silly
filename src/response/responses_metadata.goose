// Metadata composition is bounded before allocation and rejects control-byte injection.
namespace silly;

import std;

import.response;
import.responses_types;

fn printable_metadata(value: u8[:]) -> bool {
    for byte in value {
        if byte < 32 || byte >= 127 {
            return false;
        }
    }
    return true;
}

fn valid_body_type(value: u8[:]) -> bool {
    let slash = find(value, "/");
    return slash > 0 && slash < value.len - 1
        && valid_header_name(value[..slash]) && valid_header_name(value[slash + 1..]);
}

fn body_metadata(response: Response&, options: BodyOptions) -> ResponseError {
    if (options.content_type.len != 0 && !valid_body_type(options.content_type))
        || (options.charset.len != 0 && (options.content_type.len == 0 || !valid_header_name(options.charset)))
        || !printable_metadata(options.content_disposition) {
        return fail_response(response, ResponseError.InvalidHeader);
    }
    if options.content_type.len != 0 {
        let error = body_content_type(response, options);
        if error != ResponseError.None {
            return error;
        }
    }
    if options.content_disposition.len != 0 {
        return add_header(response, "Content-Disposition", options.content_disposition);
    }
    return ResponseError.None;
}

fn body_content_type(response: Response&, options: BodyOptions) -> ResponseError {
    let remaining = response.limits.header_bytes_max - response.header_bytes.len;
    if remaining < 12 || options.content_type.len > remaining - 12 {
        return fail_response(response, ResponseError.HeaderBytesLimit);
    }
    if options.charset.len == 0 {
        return add_header(response, "Content-Type", options.content_type);
    }
    let available = remaining - 12 - options.content_type.len;
    if available < 10 || options.charset.len > available - 10 {
        return fail_response(response, ResponseError.HeaderBytesLimit);
    }
    let value = str(options.content_type, "; charset=", options.charset);
    return add_header(response, "Content-Type", value);
}

fn valid_attachment_name(name: u8[:]) -> bool {
    if name.len == 0 || name == "." || name == ".." || !printable_metadata(name) {
        return false;
    }
    for byte in name {
        if byte == '/' || byte == '\\' {
            return false;
        }
    }
    return true;
}

fn attachment_disposition(response: Response&, name: u8[:], output: u8[>..]&) -> ResponseError {
    if !valid_attachment_name(name) {
        return fail_response(response, ResponseError.InvalidHeader);
    }
    let available = response.limits.header_bytes_max - response.header_bytes.len;
    // Header name plus attachment; filename="..." with the closing quote.
    if available < 42 || name.len > available - 42 {
        return fail_response(response, ResponseError.HeaderBytesLimit);
    }
    var escaped = name.len;
    for byte in name {
        if byte == '"' {
            if escaped == available - 42 {
                return fail_response(response, ResponseError.HeaderBytesLimit);
            }
            escaped += 1;
        }
    }
    output.append("attachment; filename=\"");
    for byte in name {
        if byte == '"' {
            output.push('\\');
        }
        output.push(byte);
    }
    output.push('"');
    return ResponseError.None;
}

fn valid_redirect(status: i32, location: u8[:]) -> ResponseError {
    if status != 301 && status != 302 && status != 303 && status != 307 && status != 308 {
        return ResponseError.InvalidStatus;
    }
    if location.len == 0 || !printable_metadata(location) {
        return ResponseError.InvalidHeader;
    }
    for byte in location {
        if byte == ' ' {
            return ResponseError.InvalidHeader;
        }
    }
    return ResponseError.None;
}
