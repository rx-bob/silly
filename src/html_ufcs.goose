// The static HTML renderer runs synchronously within the current endpoint.

import.context;
import.html;

fn html<A, S, F>(ctx: silly::Context<A, S> & , status: i32) {
    silly::html(ctx, status, F);
}
