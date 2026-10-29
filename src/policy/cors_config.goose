// Startup CORS validation owns its bounded strings and rejects ambiguous wildcard policy.
namespace silly;

import std;

import.cors_types;

fn cors_origin_valid(value: u8[:]) -> bool {
    if value == "null" {
        return true;
    }
    var start: i64 = 0;
    if starts_with(value, "https://") {
        start = 8;
    } else if starts_with(value, "http://") {
        start = 7;
    } else {
        return false;
    }
    for byte in value {
        if byte <= 32 || byte >= 127 || byte == '*' || byte == ',' || byte == '%' {
            return false;
        }
    }
    return valid_host(value[start..]);
}

fn cors_member(list: u8[:], value: u8[:], insensitive: bool) -> bool {
    var start: i64 = 0;
    for end in list.len + 1 {
        if end < list.len && list[end] != ',' {
            continue;
        }
        let token = trim_http_space(list[start..end]);
        if if insensitive {
            header_name_equal(token, value)
        } else {
            token == value
        }
        {
            return true;
        }
        start = end + 1;
    }
    return false;
}

fn cors_list_valid(value: u8[:], origins: bool) -> bool {
    if value.len == 0 {
        return !origins;
    }
    var start: i64 = 0;
    for end in value.len + 1 {
        if end < value.len && value[end] != ',' {
            if value[end] < 32 || value[end] >= 127 {
                return false;
            }
            continue;
        }
        let token = trim_http_space(value[start..end]);
        if origins {
            if token.len > 512 || !cors_origin_valid(token) {
                return false;
            }
        } else if token == "*" || !valid_header_name(token) {
            return false;
        }
        start = end + 1;
    }
    return true;
}

fn cors_printable(value: u8[:]) -> bool {
    for byte in value {
        if byte < 32 || byte >= 127 {
            return false;
        }
    }
    return true;
}

fn compile_cors(policy: CorsPolicy) -> CorsConfig {
    var result = CorsConfig {
    };
    let origins = trim_http_space(if policy.origin.len != 0 {
            policy.origin
        } else {
            policy.origins
        });
    if !cors_printable(policy.origin) || !cors_printable(policy.origins) || find(policy.origin, ",") >= 0
        || (policy.origin.len != 0 && policy.origins.len != 0)
        || (policy.preflight_status < 200 || policy.preflight_status > 299) || policy.max_age_seconds < 0
        || (origins == "*" && policy.credentials)
        || (origins.len != 0 && origins != "*" && !cors_list_valid(origins, true))
        || !cors_list_valid(policy.methods, false) || policy.methods.len == 0
        || !cors_list_valid(policy.headers, false) || !cors_list_valid(policy.expose_headers, false) {
        result.error = ResponseError.InvalidHeader;
        return result;
    }
    if origins.len > result.origins.cap || policy.methods.len > result.methods.cap
        || policy.headers.len > result.headers.cap || policy.expose_headers.len > result.expose_headers.cap {
        result.error = ResponseError.HeaderBytesLimit;
        return result;
    }
    result.enabled = origins.len != 0;
    result.origins.append(origins);
    result.methods.append(policy.methods);
    result.headers.append(policy.headers);
    result.expose_headers.append(policy.expose_headers);
    result.credentials = policy.credentials;
    result.preflight_status = policy.preflight_status;
    result.options_without_origin = policy.options_without_origin;
    result.max_age_seconds = policy.max_age_seconds;
    return result;
}
