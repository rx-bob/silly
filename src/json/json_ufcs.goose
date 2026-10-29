// Typed JSON bridges support the reference handler syntax without runtime callbacks.

import.json_response;
import.json_writer_types;

fn json<A, S, T>(ctx: silly::Context<A, S> & , status: i32, value: T&,
    options: silly::JsonWriteOptions = silly::JsonWriteOptions {
    }) {
    silly::json(ctx, status, value, options);
}

fn json_with_fields<A, S, T, F>(ctx: silly::Context<A, S> & , status: i32, value: T&,
    options: silly::JsonWriteOptions = silly::JsonWriteOptions {
    }) {
    silly::json_with_fields(ctx, status, value, options, F);
}

fn json_bytes<A, S>(ctx: silly::Context<A, S> & , status: i32, payload: u8[:]) {
    silly::json_bytes(ctx, status, payload);
}

fn json_with<A, S, T, W>(ctx: silly::Context<A, S> & , status: i32, value: T&,
    options: silly::JsonWriteOptions = silly::JsonWriteOptions {
    }) {
    silly::json_with(ctx, status, value, options, W);
}
