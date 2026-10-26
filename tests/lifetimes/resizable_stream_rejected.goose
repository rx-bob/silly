// Expected rejection: explicit sink initialization cannot bypass fixed-size stream-state enforcement.
namespace resizable_stream_rejected;

import silly from "../..";

import std;

struct DynamicState {
    bytes: u8[>..] = [],
}

type Context = silly::Context<silly::NoState, DynamicState>;

fn handler(ctx: Context&) {
    var state = DynamicState {
    };
    state.bytes.append("handler local");
    assert(silly::start_stream(ctx, 200, state) == silly::ResponseError.None);
}

fn::main() {
    var fields: silly::HeaderField[>..] = [];
    var headers: u8[>..] = [];
    var output: u8[>..] = [];
    var response = silly::Response {
        limits: silly::Limits {
        },
        header_fields: fields,
        header_bytes: headers,
        output: output,
        ..
    };
    let request = silly::Request {
        method: "GET",
        target: "/",
        ..
    };
    var app = silly::NoState {
    };
    var pending = silly::StreamStart<resizable_stream_rejected::DynamicState> {
        state: resizable_stream_rejected::DynamicState {
        },
        ..
    };
    var ctx = resizable_stream_rejected::Context {
        request: request,
        response: response,
        app: app,
        stream_start: pending
    };
    resizable_stream_rejected::handler(ctx);
    assert(pending.state.bytes == "handler local");
}
