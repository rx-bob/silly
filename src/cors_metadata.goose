// Canonical policy-owned CORS fields replace application conflicts before wire commitment.
namespace silly;

import std;

import.cors_config;
import.cors_types;
import.headers;
import.http_headers;
import.limits;
import.response;

fn cors_owned_header(name: u8[:]) -> bool {
    return name.len >= 15 && header_name_equal(name[..15], "Access-Control-");
}

fn cors_vary_token(output: u8[>..]&, token: u8[:], cap: i64) -> ResponseError {
    if !valid_header_name(token) {
        return ResponseError.InvalidHeader;
    }
    if output == "*" || cors_member(output, token, true) {
        return ResponseError.None;
    }
    if token == "*" {
        output.clear();
    }
    let separator: i64 = if output.len == 0 {
        0
    } else {
        2
    };
    if output.len > cap || separator > cap - output.len || token.len > cap - output.len - separator {
        return ResponseError.HeaderBytesLimit;
    }
    if separator != 0 {
        output.append(", ");
    }
    output.append(token);
    return ResponseError.None;
}

fn cors_vary_merge(output: u8[>..]&, value: u8[:], cap: i64) -> ResponseError {
    if value.len == 0 {
        return ResponseError.None;
    }
    var start: i64 = 0;
    for end in value.len + 1 {
        if end < value.len && value[end] != ',' {
            continue;
        }
        let error = cors_vary_token(output, trim_http_space(value[start..end]), cap);
        if error != ResponseError.None {
            return error;
        }
        start = end + 1;
    }
    return ResponseError.None;
}

fn cors_copy_fields(source: Response&, target: Response&, vary: u8[>..]&) -> ResponseError {
    for index in source.header_fields.len {
        let field = header_view(source.header_fields, source.header_bytes, index);
        if cors_owned_header(field.name) {
            continue;
        }
        let error = if header_name_equal(field.name, "Vary") {
            cors_vary_merge(vary, field.value, target.limits.header_bytes_max)
        } else {
            add_header(target, field.name, field.value)
        };
        if error != ResponseError.None {
            return error;
        }
    }
    return ResponseError.None;
}

fn cors_emit_fields(response: Response&, decision: CorsDecision) -> ResponseError {
    if !decision.allowed || decision.origin.len == 0 {
        return ResponseError.None;
    }
    var error = add_header(response, "Access-Control-Allow-Origin", decision.origin);
    if error == ResponseError.None && decision.credentials {
        error = add_header(response, "Access-Control-Allow-Credentials", "true");
    }
    if error == ResponseError.None && decision.methods.len != 0 {
        error = add_header(response, "Access-Control-Allow-Methods", decision.methods);
    }
    if error == ResponseError.None && decision.headers.len != 0 {
        error = add_header(response, "Access-Control-Allow-Headers", decision.headers);
    }
    if error == ResponseError.None && decision.expose_headers.len != 0 {
        error = add_header(response, "Access-Control-Expose-Headers", decision.expose_headers);
    }
    if error == ResponseError.None && decision.preflight && decision.max_age_seconds > 0 {
        error = add_header(response, "Access-Control-Max-Age", str(decision.max_age_seconds));
    }
    return error;
}

fn cors_rebuild(source: Response&, decision: CorsDecision, fields: HeaderField[>..]&,
    storage: u8[>..]&) -> ResponseError {
    var output: u8[>..] = [];
    var vary: u8[>..] = [];
    var response = Response {
        limits: source.limits,
        header_fields: fields,
        header_bytes: storage,
        output: output,
        phase: ResponsePhase.Preparing,
        ..
    };
    var error = cors_copy_fields(source, response, vary);
    if error == ResponseError.None && decision.vary_origin {
        error = cors_vary_token(vary, "Origin", response.limits.header_bytes_max);
    }
    if error == ResponseError.None && (decision.preflight || decision.vary_preflight) {
        error = cors_vary_token(vary, "Access-Control-Request-Method", response.limits.header_bytes_max);
        if error == ResponseError.None {
            error = cors_vary_token(vary, "Access-Control-Request-Headers", response.limits.header_bytes_max);
        }
    }
    if error == ResponseError.None && vary.len != 0 {
        error = add_header(response, "Vary", vary);
    }
    if error == ResponseError.None {
        error = cors_emit_fields(response, decision);
    }
    return error;
}

fn apply_cors(response: Response&, decision: CorsDecision) -> ResponseError {
    if !decision.enabled {
        return ResponseError.None;
    }
    if !valid(response.limits) {
        return fail_response(response, ResponseError.InvalidLimits);
    }
    if response.phase != ResponsePhase.Preparing && response.phase != ResponsePhase.Prepared {
        return fail_response(response, ResponseError.InvalidState);
    }
    var fields: HeaderField[>..] = [];
    var storage: u8[>..] = [];
    let error = cors_rebuild(response, decision, fields, storage);
    if error != ResponseError.None {
        return fail_response(response, error);
    }
    response.header_fields.clear();
    response.header_fields.append(fields);
    response.header_bytes.clear();
    response.header_bytes.append(storage);
    return ResponseError.None;
}
