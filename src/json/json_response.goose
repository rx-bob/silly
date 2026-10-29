// JSON response adapters preserve the precommit error boundary and opaque legacy bytes.
namespace silly;

import.json_types;
import.json_writer;
import.json_writer_types;

fn json_response_start(response: Response&, status: i32) -> ResponseError {
    let error = begin_response(response, status);
    if error != ResponseError.None {
        return fail_response(response, error);
    }
    return add_header(response, "Content-Type", "application/json");
}

fn json_response_error(error: JsonError) -> ResponseError {
    return if error == JsonError.OutputLimit {
        ResponseError.OutputLimit
    } else if error == JsonError.InvalidOptions {
        ResponseError.InvalidLimits
    } else {
        ResponseError.Application
    };
}

fn respond_json<A, S, T>(ctx: Context<A, S> & , status: i32, value: T&,
    options: JsonWriteOptions = JsonWriteOptions {
    }) -> ResponseError {
    let start = json_response_start(ctx.response, status);
    if start != ResponseError.None {
        return start;
    }
    var writer = JsonWriter {
        output: ctx.response.output,
        cap: ctx.response.limits.output_bytes_max,
        options: options,
        ..
    };
    let error = write_json(writer, value);
    if error != JsonError.None {
        return fail_response(ctx.response, json_response_error(error));
    }
    return prepare_response(ctx.response);
}

fn respond_json_with_fields<A, S, T, F>(ctx: Context<A, S> & , status: i32, value: T&,
    options: JsonWriteOptions = JsonWriteOptions {
    }) -> ResponseError {
    let start = json_response_start(ctx.response, status);
    if start != ResponseError.None {
        return start;
    }
    var writer = JsonWriter {
        output: ctx.response.output,
        cap: ctx.response.limits.output_bytes_max,
        options: options,
        ..
    };
    let error = write_json_object_with(writer, value, F);
    if error != JsonError.None {
        return fail_response(ctx.response, json_response_error(error));
    }
    return prepare_response(ctx.response);
}

fn json<A, S, T>(ctx: Context<A, S> & , status: i32, value: T&,
    options: JsonWriteOptions = JsonWriteOptions {
    }) {
    if respond_json(ctx, status, value, options) != ResponseError.None {
        reject(ctx);
    }
}

fn json_with_fields<A, S, T, F>(ctx: Context<A, S> & , status: i32, value: T&,
    options: JsonWriteOptions = JsonWriteOptions {
    }) {
    if respond_json_with_fields(ctx, status, value, options, F) != ResponseError.None {
        reject(ctx);
    }
}

// Caller owns JSON validity. Copy exact bytes without parsing, normalization or rewriting.
fn respond_json_bytes<A, S>(ctx: Context<A, S> & , status: i32, payload: u8[:]) -> ResponseError {
    let error = json_response_start(ctx.response, status);
    if error != ResponseError.None {
        return error;
    }
    let body = append_body(ctx.response, payload);
    if body != ResponseError.None {
        return body;
    }
    return prepare_response(ctx.response);
}

fn json_bytes<A, S>(ctx: Context<A, S> & , status: i32, payload: u8[:]) {
    if respond_json_bytes(ctx, status, payload) != ResponseError.None {
        reject(ctx);
    }
}

// A static writer callback composes root arrays and application-specific wire representations.
fn respond_json_with<A, S, T, W>(ctx: Context<A, S> & , status: i32, value: T&,
    options: JsonWriteOptions = JsonWriteOptions {
    }) -> ResponseError {
    let start = json_response_start(ctx.response, status);
    if start != ResponseError.None {
        return start;
    }
    var writer = JsonWriter {
        output: ctx.response.output,
        cap: ctx.response.limits.output_bytes_max,
        options: options,
        ..
    };
    W(writer, value);
    if writer.error != JsonError.None {
        return fail_response(ctx.response, json_response_error(writer.error));
    }
    return prepare_response(ctx.response);
}

fn json_with<A, S, T, W>(ctx: Context<A, S> & , status: i32, value: T&,
    options: JsonWriteOptions = JsonWriteOptions {
    }) {
    if respond_json_with(ctx, status, value, options, W) != ResponseError.None {
        reject(ctx);
    }
}
