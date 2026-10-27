// Legacy JSON readers see exact buffered bytes and retain application-owned diagnostics.
namespace silly;

import json;

import.context;
import.endpoint;
import.request;

// No media-type or JSON validation is imposed on the raw body escape hatch.
fn body<A, S>(ctx: Context<A, S> & ) -> const u8[:] {
    match body_view(ctx.request) {
        Available available => {
            return available.bytes;
        },
        Failed _ => {
            reject_empty(ctx, 400);
            return "";
        },
    }
}

fn json_reader<A, S>(ctx: Context<A, S> & ) -> json::Reader {
    return json::reader(body(ctx));
}
