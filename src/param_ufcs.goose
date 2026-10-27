// Narrow global bridge preserves the reference ctx.param(name) syntax.

import.context;
import.request;

fn param<A, S>(ctx: silly::Context<A, S> & , name: u8[:]) -> silly::FieldValue {
    return silly::param(ctx, name);
}
