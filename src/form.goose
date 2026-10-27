// Strict URL-encoded forms reuse bounded query decoding without query compatibility policies.
namespace silly;

import.context;
import.endpoint;
import.headers;
import.http_headers;
import.query;
import.query_view;
import.request;
import.request_headers;

struct FormOptions {
    input_bytes_max: i64 = 65536,
    pairs_max: i64 = 1024,
    decoded_bytes_max: i64 = 65536,
}

enum FormError {
    None,
    UnsupportedMediaType,
    BodyUnavailable,
    InvalidEncoding,
    PairLimit,
    DecodedLimit,
    InputLimit,
    InvalidOptions,
}

struct Form {
    error: FormError = FormError.None,
    pairs: QueryView,
}

// Accept the registered media type plus an optional single UTF-8 charset declaration.
// Unknown/duplicate parameters are refused rather than silently changing decoding policy.
fn form_media_type(value: u8[:]) -> bool {
    let field = trim_http_space(value);
    var separator = field.len;
    for index in field.len {
        if field[index] == ';' {
            separator = index;
            break;
        }
    }
    if !header_name_equal(trim_http_space(field[..separator]), "application/x-www-form-urlencoded") {
        return false;
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

fn form_request_media(request: Request) -> bool {
    var fields = header_values(request, "Content-Type");
    let field = next_header(fields);
    if !field.present || next_header(fields).present {
        return false;
    }
    return form_media_type(field.value);
}

fn form_query_error(error: QueryError) -> FormError {
    return match error {
        None => {
            FormError.None
        },
        InvalidEscape => {
            FormError.InvalidEncoding
        },
        PairLimit => {
            FormError.PairLimit
        },
        DecodedLimit => {
            FormError.DecodedLimit
        },
        InputLimit => {
            FormError.InputLimit
        },
        InvalidOptions => {
            FormError.InvalidOptions
        },
    };
}

fn parse_form(request: Request, scratch: u8[>..]&, options: FormOptions = FormOptions {
    }) -> Form {
    if options.input_bytes_max < 0 || options.pairs_max < 0 || options.decoded_bytes_max < 0 {
        return Form {
            pairs: QueryView {
            },
            error: FormError.InvalidOptions
        };
    }
    if !form_request_media(request) {
        return Form {
            pairs: QueryView {
            },
            error: FormError.UnsupportedMediaType
        };
    }
    match body_view(request) {
        Available body => {
            let pairs = parse_query_view(body.bytes, scratch, QueryOptions {
                    input_bytes_max: options.input_bytes_max,
                    pairs_max: options.pairs_max,
                    decoded_bytes_max: options.decoded_bytes_max,
                    ..
                });
            return Form {
                error: form_query_error(pairs.error),
                pairs: pairs
            };
        },
        Failed _ => {
            return Form {
                pairs: QueryView {
                },
                error: FormError.BodyUnavailable
            };
        },
    }
}

fn form_error_status(error: FormError) -> i32 {
    return match error {
        UnsupportedMediaType => {
            415
        },
        PairLimit => {
            413
        },
        DecodedLimit => {
            413
        },
        InputLimit => {
            413
        },
        InvalidOptions => {
            500
        },
        _ => {
            400
        },
    };
}

fn require_form<A, S>(ctx: Context<A, S> & , scratch: u8[>..]&, options: FormOptions = FormOptions {
    }) -> Form {
    let form = parse_form(ctx.request, scratch, options);
    if form.error != FormError.None {
        reject_empty(ctx, form_error_status(form.error));
    }
    return form;
}

fn get(form: const Form&, name: u8[:]) -> FieldValue {
    if form.error != FormError.None {
        return FieldValue {
        };
    }
    return get(form.pairs, name);
}

fn form_values(form: const Form&, name: u8[:]) -> QueryValues {
    return query_values(form.pairs, name);
}
