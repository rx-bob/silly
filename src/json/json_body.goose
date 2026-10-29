// Strict typed body binding is opt-in; raw bytes/readers retain application policy elsewhere.
namespace silly;

import.json_bind;
import.json_bind_types;
import.json_types;
import.json_view;

fn json_media_type(value: u8[:]) -> bool {
    let field = trim_http_space(value);
    var separator = field.len;
    for index in field.len {
        if field[index] == ';' {
            separator = index;
            break;
        }
    }
    let media = trim_http_space(field[..separator]);
    let standard = header_name_equal(media, "application/json");
    let suffix = media.len > 17 && header_name_equal(media[..12], "application/")
        && header_name_equal(media[media.len - 5..], "+json") && valid_header_name(media[12..]);
    if !standard && !suffix {
        return false;
    }
    for byte in media {
        if byte <= 32 || byte >= 127 {
            return false;
        }
    }
    if separator == field.len {
        return true;
    }
    let parameter = trim_http_space(field[separator + 1..]);
    var equals: i64 = -1;
    for index in parameter.len {
        if parameter[index] == '=' {
            equals = index;
            break;
        }
    }
    if equals < 0 || !header_name_equal(trim_http_space(parameter[..equals]), "charset") {
        return false;
    }
    let charset = trim_http_space(parameter[equals + 1..]);
    return header_name_equal(charset, "utf-8") || header_name_equal(charset, "\"utf-8\"");
}

fn json_request_media(request: Request) -> bool {
    var fields = header_values(request, "Content-Type");
    let field = next_header(fields);
    return field.present && !next_header(fields).present && json_media_type(field.value);
}

fn parse_json_body<T>(request: Request, scratch: u8[>..]&, options: JsonBindOptions = JsonBindOptions {
    })
    -> JsonBinding<T> {
    if !valid_json_bind_options(options) {
        return JsonBinding<T> {
            error: JsonError.InvalidOptions,
            ..
        };
    }
    if !json_request_media(request) {
        return JsonBinding<T> {
            error: JsonError.UnsupportedMediaType,
            ..
        };
    }
    match body_view(request) {
        Available body => {
            let document = parse_json(body.bytes, scratch, options.limits);
            if document.error != JsonError.None {
                return JsonBinding<T> {
                    error: document.error,
                    error_at: document.error_at,
                    ..
                };
            }
            return bind_json<T>(document.value, options);
        },
        Failed _ => {
            return JsonBinding<T> {
                error: JsonError.BodyUnavailable,
                ..
            };
        },
    }
}

fn json_body_error_status(error: JsonError) -> i32 {
    return if error == JsonError.UnsupportedMediaType {
        415
    } else if error == JsonError.InvalidOptions {
        500
    } else if error == JsonError.BodyLimit || error == JsonError.ScratchLimit || error == JsonError.CollectionLimit {
        413
    } else {
        400
    };
}

fn require_json_binding<T, A, S>(ctx: Context<A, S> & , scratch: u8[>..]&,
    options: JsonBindOptions = JsonBindOptions {
    }) -> JsonBinding<T> {
    // Fixed-size T avoids the pinned compiler's nonlocal owned-result initialization defect.
    let fixed = default<T>();
    let bound = parse_json_body<T>(ctx.request, scratch, options);
    if bound.error != JsonError.None {
        reject_empty(ctx, json_body_error_status(bound.error));
    }
    return bound;
}

fn require_json<T, A, S>(ctx: Context<A, S> & , scratch: u8[>..]&,
    options: JsonBindOptions = JsonBindOptions {
    }) -> T {
    let fixed = default<T>();
    return require_json_binding<T>(ctx, scratch, options).value;
}
