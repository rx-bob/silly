// Buffered response helpers copy application bytes and prepare exactly one response.
namespace silly;

import.context;
import.endpoint;
import.response;
import.responses_metadata;
import.responses_types;

fn start_body_response(response: Response&, status: i32) -> ResponseError {
    let error = begin_response(response, status);
    return if error == ResponseError.None {
        error
    } else {
        fail_response(response, error)
    };
}

fn finish_body_response(response: Response&, payload: u8[:], options: BodyOptions) -> ResponseError {
    let metadata = body_metadata(response, options);
    if metadata != ResponseError.None {
        return metadata;
    }
    let error = append_body(response, payload);
    if error != ResponseError.None {
        return error;
    }
    return prepare_response(response);
}

fn respond_bytes<A, S>(ctx: Context<A, S> & , status: i32, payload: u8[:],
    options: BodyOptions = BodyOptions {
    }) -> ResponseError {
    let error = start_body_response(ctx.response, status);
    if error != ResponseError.None {
        return error;
    }
    return finish_body_response(ctx.response, payload, options);
}

fn respond_attachment<A, S>(ctx: Context<A, S> & , status: i32, payload: u8[:],
    attachment: Attachment) -> ResponseError {
    let error = start_body_response(ctx.response, status);
    if error != ResponseError.None {
        return error;
    }
    var disposition: u8[>..] = [];
    let named = attachment_disposition(ctx.response, attachment.filename, disposition);
    if named != ResponseError.None {
        return named;
    }
    return finish_body_response(ctx.response, payload, BodyOptions {
            content_type: attachment.content_type,
            charset: attachment.charset,
            content_disposition: disposition,
        });
}

fn respond_redirect<A, S>(ctx: Context<A, S> & , status: i32, location: u8[:]) -> ResponseError {
    let error = start_body_response(ctx.response, status);
    if error != ResponseError.None {
        return error;
    }
    let valid = valid_redirect(status, location);
    if valid != ResponseError.None {
        return fail_response(ctx.response, valid);
    }
    let header = add_header(ctx.response, "Location", location);
    if header != ResponseError.None {
        return header;
    }
    return prepare_response(ctx.response);
}

fn text<A, S>(ctx: Context<A, S> & , status: i32, payload: u8[:]) {
    if respond_text(ctx, status, payload) != ResponseError.None {
        reject(ctx);
    }
}

fn empty<A, S>(ctx: Context<A, S> & , status: i32) {
    if respond_empty(ctx, status) != ResponseError.None {
        reject(ctx);
    }
}

fn bytes<A, S>(ctx: Context<A, S> & , status: i32, payload: u8[:], options: BodyOptions = BodyOptions {
    }) {
    if respond_bytes(ctx, status, payload, options) != ResponseError.None {
        reject(ctx);
    }
}

fn attachment<A, S>(ctx: Context<A, S> & , status: i32, payload: u8[:], attachment: Attachment) {
    if respond_attachment(ctx, status, payload, attachment) != ResponseError.None {
        reject(ctx);
    }
}

fn redirect<A, S>(ctx: Context<A, S> & , status: i32, location: u8[:]) {
    if respond_redirect(ctx, status, location) != ResponseError.None {
        reject(ctx);
    }
}
