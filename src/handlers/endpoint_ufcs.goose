// Narrow global bridges preserve method syntax without storing runtime callbacks.

import.context;
import.endpoint;

fn respond_text<A, S>(ctx: silly::Context<A, S> & , status: i32, payload: u8[:]) -> silly::ResponseError {
    return silly::respond_text(ctx, status, payload);
}

fn respond_empty<A, S>(ctx: silly::Context<A, S> & , status: i32) -> silly::ResponseError {
    return silly::respond_empty(ctx, status);
}

fn reject_text<A, S>(ctx: silly::Context<A, S> & , status: i32, payload: u8[:]) {
    silly::reject_text(ctx, status, payload);
}

fn reject_empty<A, S>(ctx: silly::Context<A, S> & , status: i32) {
    silly::reject_empty(ctx, status);
}

fn reject<A, S>(ctx: silly::Context<A, S> & ) {
    silly::reject(ctx);
}
