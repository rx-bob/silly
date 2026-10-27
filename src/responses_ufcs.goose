// Public method syntax delegates synchronously without retaining callbacks or input bytes.

import.context;
import.response;
import.responses;
import.responses_types;

fn text<A, S>(ctx: silly::Context<A, S> & , status: i32, payload: u8[:]) {
    silly::text(ctx, status, payload);
}

fn empty<A, S>(ctx: silly::Context<A, S> & , status: i32) {
    silly::empty(ctx, status);
}

fn bytes<A, S>(ctx: silly::Context<A, S> & , status: i32, payload: u8[:],
    options: silly::BodyOptions = silly::BodyOptions {
    }) {
    silly::bytes(ctx, status, payload, options);
}

fn attachment<A, S>(ctx: silly::Context<A, S> & , status: i32, payload: u8[:], attachment: silly::Attachment) {
    silly::attachment(ctx, status, payload, attachment);
}

fn redirect<A, S>(ctx: silly::Context<A, S> & , status: i32, location: u8[:]) {
    silly::redirect(ctx, status, location);
}

fn respond_bytes<A, S>(ctx: silly::Context<A, S> & , status: i32, payload: u8[:],
    options: silly::BodyOptions = silly::BodyOptions {
    }) -> silly::ResponseError {
    return silly::respond_bytes(ctx, status, payload, options);
}

fn respond_attachment<A, S>(ctx: silly::Context<A, S> & , status: i32, payload: u8[:],
    attachment: silly::Attachment) -> silly::ResponseError {
    return silly::respond_attachment(ctx, status, payload, attachment);
}

fn respond_redirect<A, S>(ctx: silly::Context<A, S> & , status: i32, location: u8[:]) -> silly::ResponseError {
    return silly::respond_redirect(ctx, status, location);
}
