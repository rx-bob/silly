// Raw body method syntax retains the same endpoint-scoped borrowed bytes.

import json;

import.context;
import.json_raw_body;

fn body<A, S>(ctx: silly::Context<A, S> & ) -> const u8[:] {
    return silly::body(ctx);
}

fn json_reader<A, S>(ctx: silly::Context<A, S> & ) -> json::Reader {
    return silly::json_reader(ctx);
}
