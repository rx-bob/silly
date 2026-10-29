// Global method bridge preserves the static owned-state selection contract.

import.sse_context;

fn events<A, S>(ctx: silly::Context<A, S> & , state: S,
    options: silly::SseOptions = silly::SseOptions {
    }) -> silly::ResponseError {
    return silly::events(ctx, state, options);
}
