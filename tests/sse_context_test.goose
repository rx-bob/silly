// Metadata failures leave resource-bearing state with the caller, never a selected producer.
namespace sse_context_test;

import silly from "..";

import std;

struct State {
    token: i64 = 0
}

fn selection(limits: silly::Limits, options: silly::SseOptions, expected: silly::ResponseError) {
    var fields: silly::HeaderField[>..] = [];
    var headers: u8[>..] = [];
    var bytes: u8[>..] = [];
    var response = silly::Response {
        limits: limits,
        header_fields: fields,
        header_bytes: headers,
        output: bytes,
        ..
    };
    var app = silly::NoState {
    };
    let request = silly::Request {
        method: "GET",
        target: "/events",
        ..
    };
    var sink = silly::StreamStart<State> {
        state: State {
            token: 99
        },
        ..
    };
    var ctx = silly::Context<silly::NoState, State> {
        request: request,
        response: response,
        app: app,
        stream_start: sink,
        ..
    };
    assert(ctx.events(State {
            token: 7
        }, options) == expected);
    if expected != silly::ResponseError.None {
        assert(!sink.selected);
        assert(sink.state.token == 99);
        return;
    }
    assert(sink.selected);
    assert(sink.state.token == 7);
    assert(sink.pending_bytes_max == options.pending_bytes_max);
    assert(response.phase == silly::ResponsePhase.Prepared);
    assert(response.mode == silly::ResponseBodyMode.Stream);
    assert(response.status == 200);
    assert(fields.len == 2);
    assert(silly::header_view(fields, headers, 0).value == "text/event-stream");
    assert(silly::header_view(fields, headers, 1).value == options.cache_control);
    assert(ctx.events(State {
            token: 8
        }) == silly::ResponseError.AlreadyStarted);
    assert(sink.state.token == 7);
}

fn::main() {
    sse_context_test::selection(silly::Limits {
        }, silly::SseOptions {
        }, silly::ResponseError.None);
    sse_context_test::selection(silly::Limits {
        }, silly::SseOptions {
            pending_bytes_max: 64,
            cache_control: "no-store",
            ..
        }, silly::ResponseError.None);
    sse_context_test::selection(silly::Limits {
            header_count_max: 1,
            ..
        }, silly::SseOptions {
        },
        silly::ResponseError.HeaderCountLimit);
    sse_context_test::selection(silly::Limits {
            header_bytes_max: 32,
            ..
        }, silly::SseOptions {
        },
        silly::ResponseError.HeaderBytesLimit);
    sse_context_test::selection(silly::Limits {
        }, silly::SseOptions {
            cache_control: "no-cache\r\nX-Injected: yes",
            ..
        }, silly::ResponseError.InvalidHeader);
    sse_context_test::selection(silly::Limits {
        }, silly::SseOptions {
            pending_bytes_max: 0,
            ..
        },
        silly::ResponseError.InvalidLimits);
    print("SSE selection preserves ownership on metadata failure");
}
