// Strict request framing policy; raw ordered fields remain untouched for application lookup.
namespace silly;

import.http_head_types;
import.http_host;

struct FramingFields {
    host_count: i64 = 0,
    length_seen: bool = false,
    length: i64 = 0,
    coding_count: i64 = 0,
    chunked_count: i64 = 0,
    unsupported_coding: bool = false,
    authorization: bool = false,
    proxy_authorization: bool = false,
    content_type: bool = false,
}

fn validate_head_fields(fields: HeaderView[:], http_minor: i32) -> HeadFraming {
    var state = FramingFields {
    };
    for field in fields {
        let result = framing_field(state, field);
        if result != HeadResult.Complete {
            return HeadFraming {
                result: result,
                ..
            };
        }
    }
    if (http_minor == 1 && state.host_count != 1)
        || (state.length_seen && state.coding_count != 0)
        || (http_minor == 0 && state.coding_count != 0)
        || (state.coding_count != 0 && state.chunked_count != 1) {
        return HeadFraming {
            result: HeadResult.BadRequest,
            ..
        };
    }
    if state.unsupported_coding {
        return HeadFraming {
            result: HeadResult.UnsupportedTransferCoding,
            ..
        };
    }
    if state.coding_count > 0 {
        return HeadFraming {
            kind: BodyFraming.Chunked,
            ..
        };
    }
    if state.length_seen {
        return HeadFraming {
            kind: BodyFraming.Fixed,
            content_length: state.length,
            ..
        };
    }
    return HeadFraming {
    };
}

fn framing_field(state: FramingFields&, field: HeaderView) -> HeadResult {
    if header_name_equal(field.name, "Host") {
        state.host_count += 1;
        if state.host_count != 1 || !valid_host(trim_http_space(field.value)) {
            return HeadResult.BadRequest;
        }
    } else if header_name_equal(field.name, "Content-Length") {
        return parse_content_lengths(state, field.value);
    } else if header_name_equal(field.name, "Transfer-Encoding") {
        return parse_transfer_codings(state, field.value);
    } else if header_name_equal(field.name, "Authorization") {
        if state.authorization {
            return HeadResult.BadRequest;
        }
        state.authorization = true;
    } else if header_name_equal(field.name, "Proxy-Authorization") {
        if state.proxy_authorization {
            return HeadResult.BadRequest;
        }
        state.proxy_authorization = true;
    } else if header_name_equal(field.name, "Content-Type") {
        if state.content_type {
            return HeadResult.BadRequest;
        }
        state.content_type = true;
    }
    return HeadResult.Complete;
}

// RFC 9110 permits identical decimal lengths in repeated/list-valued fields.
fn parse_content_lengths(state: FramingFields&, value: u8[:]) -> HeadResult {
    var start = 0;
    for end in value.len + 1 {
        if end < value.len && value[end] != ',' {
            continue;
        }
        let item = trim_http_space(value[start..end]);
        if item.len == 0 {
            return HeadResult.BadRequest;
        }
        var length: i64 = 0;
        for byte in item {
            if byte < '0' || byte > '9' {
                return HeadResult.BadRequest;
            }
            let digit: i64 = byte - '0';
            if length > (9223372036854775807 - digit) / 10 {
                return HeadResult.BadRequest;
            }
            length = length * 10 + digit;
        }
        if state.length_seen && state.length != length {
            return HeadResult.BadRequest;
        }
        state.length_seen = true;
        state.length = length;
        start = end + 1;
    }
    return HeadResult.Complete;
}

// Supported set is exactly one chunked coding. Other token codings are classified unsupported.
fn parse_transfer_codings(state: FramingFields&, value: u8[:]) -> HeadResult {
    var start = 0;
    for end in value.len + 1 {
        if end < value.len && value[end] != ',' {
            continue;
        }
        let item = trim_http_space(value[start..end]);
        if !valid_header_name(item) || state.chunked_count != 0 {
            return HeadResult.BadRequest;
        }
        state.coding_count += 1;
        if header_name_equal(item, "chunked") {
            state.chunked_count += 1;
        } else {
            state.unsupported_coding = true;
        }
        start = end + 1;
    }
    return HeadResult.Complete;
}

fn trim_http_space(value: u8[:]) -> const u8[:] {
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
