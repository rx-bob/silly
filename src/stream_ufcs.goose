// Global method bridge keeps static producer callbacks outside runtime state.

import.context;
import.response;
import.stream_context;

fn stream<A, S>(ctx: silly::Context<A, S> & , status: i32, state: S,
    options: silly::StreamOptions = silly::StreamOptions {
    }) -> silly::ResponseError {
    return silly::stream(ctx, status, state, options);
}

fn stream_input<A, S>(ctx: silly::Context<A, S> & , status: i32, state: S,
    options: silly::StreamOptions = silly::StreamOptions {
    }) -> silly::ResponseError {
    return silly::stream_input(ctx, status, state, options);
}
