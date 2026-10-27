// Per-request CORS decisions depend only on a validated head and fixed startup policy.
namespace silly;

import.cors_config;
import.cors_metadata;
import.cors_types;
import.headers;
import.http_headers;
import.response;

struct CorsInput {
    origin: const u8[:] = "",
    method: const u8[:] = "",
    headers: const u8[:] = "",
    origin_count: i64 = 0,
    method_count: i64 = 0,
    headers_count: i64 = 0,
}

fn cors_input(fields: HeaderView[:]) -> CorsInput {
    var result = CorsInput {
    };
    for field in fields {
        if header_name_equal(field.name, "Origin") {
            result.origin = trim_http_space(field.value);
            result.origin_count += 1;
        } else if header_name_equal(field.name, "Access-Control-Request-Method") {
            result.method = trim_http_space(field.value);
            result.method_count += 1;
        } else if header_name_equal(field.name, "Access-Control-Request-Headers") {
            result.headers = trim_http_space(field.value);
            result.headers_count += 1;
        }
    }
    return result;
}

fn cors_requested_headers(allowed: u8[:], requested: u8[:]) -> bool {
    if requested.len == 0 {
        return true;
    }
    var start: i64 = 0;
    for end in requested.len + 1 {
        if end < requested.len && requested[end] != ',' {
            continue;
        }
        if !cors_member(allowed, trim_http_space(requested[start..end]), true) {
            return false;
        }
        start = end + 1;
    }
    return true;
}

// Request list OWS includes TAB; only trimmed field-name tokens are compared or accepted.
fn cors_request_list_valid(value: u8[:]) -> bool {
    if value.len == 0 {
        return true;
    }
    var start: i64 = 0;
    for end in value.len + 1 {
        if end < value.len && value[end] != ',' {
            continue;
        }
        let token = trim_http_space(value[start..end]);
        if token == "*" || !valid_header_name(token) {
            return false;
        }
        start = end + 1;
    }
    return true;
}

fn cors_preflight(config: CorsConfig, input: CorsInput) -> i32 {
    if input.method_count > 1 || input.headers_count > 1 || input.headers.len > 512
        || (input.method_count == 1 && !valid_header_name(input.method))
        || !cors_request_list_valid(input.headers) {
        return 400;
    }
    if input.method_count == 0 {
        return if config.options_without_origin && input.headers_count == 0 {
            config.preflight_status
        } else {
            400
        };
    }
    if input.origin_count == 0 && !config.options_without_origin {
        return 400;
    }
    if !cors_member(config.methods, input.method, false) || !cors_requested_headers(config.headers, input.headers) {
        return 403;
    }
    return config.preflight_status;
}

fn decide_cors(config: CorsConfig, method: u8[:], fields: HeaderView[:]) -> CorsDecision {
    var result = CorsDecision {
        enabled: config.enabled,
        ..
    };
    if !config.enabled {
        return result;
    }
    let input = cors_input(fields);
    result.vary_origin = config.origins != "*";
    result.vary_preflight = method == "OPTIONS";
    result.preflight = method == "OPTIONS" && (input.method_count != 0 || input.headers_count != 0
        || config.options_without_origin);
    if input.origin_count > 1 || input.origin.len > result.origin.cap
        || (input.origin_count == 1 && !cors_origin_valid(input.origin)) {
        result.early_status = 400;
        return result;
    }
    result.allowed = config.origins == "*"
        || (input.origin_count == 1 && cors_member(config.origins, input.origin, false));
    if input.origin_count == 1 && !result.allowed {
        result.early_status = 403;
        return result;
    }
    if result.allowed {
        result.origin.append(if config.origins == "*" {
                "*"
            } else {
                input.origin
            });
        result.methods = config.methods;
        result.headers = config.headers;
        result.expose_headers = config.expose_headers;
        result.credentials = config.credentials;
        result.max_age_seconds = config.max_age_seconds;
    }
    if result.preflight {
        result.early_status = cors_preflight(config, input);
    } else if input.origin_count == 1 && !cors_member(config.methods, method, false) {
        result.early_status = 403;
    }
    return result;
}
