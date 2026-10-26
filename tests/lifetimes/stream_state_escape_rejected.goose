// Expected rejection: fixed-size state still cannot retain handler-local byte references.
namespace stream_state_escape_rejected;

import silly from "../..";

import std;

struct BorrowedState {
    bytes: const u8[:] = "",
}

type Context = silly::Context<silly::NoState, BorrowedState>;

fn handler(ctx: Context&) {
    var temporary: u8[>..] = [];
    temporary.append("handler local");
    let state = BorrowedState {
        bytes: temporary
    };
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
    var pending = silly::StreamStart<stream_state_escape_rejected::BorrowedState> {
    };
    var ctx = stream_state_escape_rejected::Context {
        request: request,
        response: response,
        app: app,
        stream_start: pending
    };
    stream_state_escape_rejected::handler(ctx);
    assert(pending.state.bytes == "handler local");
}
