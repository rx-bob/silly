// Request borrows, response transitions and deterministic memory transport behavior.
namespace context_test;

import silly from "..";

import std;

struct App {
    calls: i64 = 0,
}

enum AppError {
    Denied,
}

type Context = silly::Context<App, silly::NoStream>;

fn with_response<F>(limits: silly::Limits) {
    var fields: silly::HeaderField[>..] = [];
    var headers: u8[>..] = [];
    var output: u8[>..] = [];
    var response = silly::Response {
        limits: limits,
        header_fields: fields,
        header_bytes: headers,
        output: output,
        ..
    };
    F(response);
}

fn normal_handler(response: silly::Response&) {
    var input: u8[>..] = [];
    input.append("payload");
    const headers = [silly::HeaderView {
            name: "X-Test",
            value: " \tvalue \t"
        },
        silly::HeaderView {
            name: "X-Empty",
            value: ""
        }];
    let request = silly::Request {
        method: "POST",
        target: "/echo",
        headers: headers,
        body_state: silly::RequestBody.Buffered {
            bytes: input
        },
    };
    var app = App {
    };
    var ctx = silly::Context<App, silly::NoStream> {
        request: request,
        response: response,
        app: app,
    };
    assert(ctx.request.method == "POST");
    assert(silly::header(ctx, "x-test").value == "value");
    assert(silly::header_raw(ctx, "X-Test").value == "value \t");
    assert(silly::header(ctx, "X-Empty").present);
    assert(silly::header(ctx, "X-Empty").value.len == 0);
    assert(!silly::header(ctx, "Absent").present);
    ctx.app.calls += 1;
    assert(app.calls == 1);
    assert(silly::begin_response(ctx.response, 200) == silly::ResponseError.None);
    match silly::body_view(ctx) {
        Available body => {
            assert(silly::append_body(ctx.response, body.bytes) == silly::ResponseError.None);
        },
        _ => {
            assert(false);
        },
    }
    assert(silly::prepare_response(ctx.response) == silly::ResponseError.None);
    assert(silly::handler_outcome(response, silly::RouteSelection.Matched) == silly::HandlerOutcome.Prepared);
    assert(response.output == "payload");
}

fn empty_and_missing(response: silly::Response&) {
    assert(silly::handler_outcome(response, silly::RouteSelection.Matched) == silly::HandlerOutcome.MissingResponse);
    assert(silly::handler_outcome(response, silly::RouteSelection.NotFound) == silly::HandlerOutcome.RouteNotFound);
    assert(silly::commit_response(response) == silly::ResponseError.InvalidState);
    assert(silly::begin_response(response, 204) == silly::ResponseError.None);
    assert(silly::prepare_response(response) == silly::ResponseError.None);
    assert(silly::handler_outcome(response, silly::RouteSelection.Matched) == silly::HandlerOutcome.Prepared);
    assert(silly::commit_response(response) == silly::ResponseError.None);
    var transport = silly::MemoryTransport {
        capacity: 0,
        ..
    };
    assert(silly::drain_memory(transport, response, 0) == silly::DrainResult.Complete);
    assert(transport.bytes.len == 0);
    assert(transport.terminal_count == 1);
    assert(!silly::complete_response(response));
    assert(!silly::cancel_response(response, silly::ResponseError.Transport));
}

fn duplicate_and_commit(response: silly::Response&) {
    assert(silly::begin_response(response, 201) == silly::ResponseError.None);
    assert(silly::append_body(response, "first") == silly::ResponseError.None);
    assert(silly::begin_response(response, 500) == silly::ResponseError.AlreadyStarted);
    assert(response.status == 201);
    assert(response.output == "first");
    assert(silly::add_header(response, "X-One", "before") == silly::ResponseError.None);
    assert(silly::prepare_response(response) == silly::ResponseError.None);
    assert(silly::add_header(response, "X-Two", "prepared") == silly::ResponseError.None);
    assert(silly::set_status(response, 202) == silly::ResponseError.None);
    assert(silly::commit_response(response) == silly::ResponseError.None);
    assert(silly::add_header(response, "X-Three", "late") == silly::ResponseError.InvalidState);
    assert(silly::set_status(response, 500) == silly::ResponseError.InvalidState);
    assert(silly::append_body(response, "second") == silly::ResponseError.InvalidState);
    assert(silly::begin_response(response, 500) == silly::ResponseError.AlreadyStarted);
    assert(response.header_fields.len == 2);
    assert(response.status == 202);
    assert(response.output == "first");
    assert(response.phase == silly::ResponsePhase.Committed);
}

fn output_limit(response: silly::Response&) {
    assert(silly::begin_response(response, 200) == silly::ResponseError.None);
    assert(silly::append_body(response, "abc") == silly::ResponseError.None);
    assert(silly::append_body(response, "d") == silly::ResponseError.OutputLimit);
    assert(response.output == "abc");
    assert(response.phase == silly::ResponsePhase.Failed);
    match silly::handler_outcome(response, silly::RouteSelection.Matched) {
        Failed failure => {
            assert(failure.error == silly::ResponseError.OutputLimit);
        },
        _ => {
            assert(false);
        },
    }
    assert(silly::prepare_response(response) == silly::ResponseError.InvalidState);
    assert(silly::commit_response(response) == silly::ResponseError.InvalidState);
}

fn header_count_limit(response: silly::Response&) {
    assert(silly::begin_response(response, 200) == silly::ResponseError.None);
    assert(silly::add_header(response, "X", "a") == silly::ResponseError.None);
    assert(silly::add_header(response, "X", "b") == silly::ResponseError.HeaderCountLimit);
    assert(response.header_fields.len == 1);
    assert(response.header_bytes == "Xa");
    assert(response.phase == silly::ResponsePhase.Failed);
}

fn header_bytes_limit(response: silly::Response&) {
    assert(silly::begin_response(response, 200) == silly::ResponseError.None);
    assert(silly::add_header(response, "X", "abc") == silly::ResponseError.HeaderBytesLimit);
    assert(response.header_fields.len == 0);
    assert(response.header_bytes.len == 0);
    assert(response.phase == silly::ResponsePhase.Failed);
}

fn invalid_header(response: silly::Response&) {
    assert(silly::begin_response(response, 200) == silly::ResponseError.None);
    assert(silly::add_header(response, "X", "bad\r\nInjected: yes") == silly::ResponseError.InvalidHeader);
    assert(response.header_fields.len == 0);
    assert(response.phase == silly::ResponsePhase.Failed);
}

fn invalid_status(response: silly::Response&) {
    assert(silly::begin_response(response, 99) == silly::ResponseError.InvalidStatus);
    assert(response.phase == silly::ResponsePhase.Failed);
    assert(response.status == 0);
}

fn invalid_limits(response: silly::Response&) {
    assert(silly::begin_response(response, 200) == silly::ResponseError.InvalidLimits);
    assert(response.phase == silly::ResponsePhase.Failed);
}

fn partial_drain(response: silly::Response&) {
    assert(silly::begin_response(response, 200) == silly::ResponseError.None);
    assert(silly::append_body(response, "abcdef") == silly::ResponseError.None);
    assert(silly::prepare_response(response) == silly::ResponseError.None);
    assert(silly::commit_response(response) == silly::ResponseError.None);
    var transport = silly::MemoryTransport {
        capacity: 6,
        ..
    };
    assert(silly::drain_memory(transport, response, 0) == silly::DrainResult.Blocked);
    assert(response.sent_bytes == 0);
    assert(silly::drain_memory(transport, response, 2) == silly::DrainResult.Progress);
    assert(transport.bytes == "ab");
    assert(!silly::complete_response(response));
    assert(silly::drain_memory(transport, response, 3) == silly::DrainResult.Progress);
    assert(transport.bytes == "abcde");
    assert(silly::drain_memory(transport, response, 100) == silly::DrainResult.Complete);
    assert(transport.bytes == "abcdef");
    assert(transport.terminal_count == 1);
    assert(silly::drain_memory(transport, response, 100) == silly::DrainResult.InvalidState);
    assert(transport.terminal_count == 1);
}

fn disconnect_drain(response: silly::Response&) {
    assert(silly::begin_response(response, 200) == silly::ResponseError.None);
    assert(silly::append_body(response, "abcdef") == silly::ResponseError.None);
    assert(silly::prepare_response(response) == silly::ResponseError.None);
    assert(silly::commit_response(response) == silly::ResponseError.None);
    var transport = silly::MemoryTransport {
        capacity: 2,
        ..
    };
    assert(silly::drain_memory(transport, response, 10) == silly::DrainResult.Progress);
    assert(silly::drain_memory(transport, response, 10) == silly::DrainResult.Blocked);
    transport.disconnected = true;
    assert(silly::drain_memory(transport, response, 10) == silly::DrainResult.Failed);
    assert(response.phase == silly::ResponsePhase.Cancelled);
    assert(response.error == silly::ResponseError.Transport);
    assert(transport.bytes == "ab");
    assert(transport.terminal_count == 1);
    assert(silly::drain_memory(transport, response, 10) == silly::DrainResult.InvalidState);
    assert(!silly::cancel_response(response, silly::ResponseError.Transport));
    assert(transport.terminal_count == 1);
}

fn render_error(ctx: Context&, error: AppError) {
    assert(error == AppError.Denied);
    ctx.app.calls += 1;
    assert(silly::begin_response(ctx.response, 403) == silly::ResponseError.None);
    assert(silly::append_body(ctx.response, "app denied") == silly::ResponseError.None);
    assert(silly::prepare_response(ctx.response) == silly::ResponseError.None);
}

fn custom_error(response: silly::Response&) {
    let request = silly::Request {
        method: "GET",
        target: "/",
        ..
    };
    var app = App {
    };
    var ctx = silly::Context<App, silly::NoStream> {
        request: request,
        response: response,
        app: app
    };
    assert(silly::convert_error(ctx, AppError.Denied, render_error) == silly::HandlerOutcome.Prepared);
    assert(response.status == 403);
    assert(response.output == "app denied");
    match silly::convert_error(ctx, AppError.Denied, render_error) {
        Failed failure => {
            assert(failure.error == silly::ResponseError.AlreadyStarted);
        },
        _ => {
            assert(false);
        },
    }
    assert(app.calls == 1);
    assert(silly::commit_response(response) == silly::ResponseError.None);
    match silly::convert_error(ctx, AppError.Denied, render_error) {
        Failed failure => {
            assert(failure.error == silly::ResponseError.Application);
        },
        _ => {
            assert(false);
        },
    }
    assert(response.phase == silly::ResponsePhase.Cancelled);
    assert(app.calls == 1);
    assert(response.output == "app denied");
}

fn recover_failed_builder() {
    var fields: silly::HeaderField[>..] = [];
    var headers: u8[>..] = [];
    var output: u8[>..] = [];
    {
        var response = silly::Response {
            limits: silly::Limits {
                output_bytes_max: 3,
                ..
            },
            header_fields: fields,
            header_bytes: headers,
            output: output,
            ..
        };
        output_limit(response);
    }
    fields.clear();
    headers.clear();
    output.clear();
    {
        var response = silly::Response {
            limits: silly::Limits {
            },
            header_fields: fields,
            header_bytes: headers,
            output: output,
            ..
        };
        custom_error(response);
        assert(response.output == "app denied");
    }
}

fn body_states() {
    let streamed = silly::Request {
        method: "POST",
        target: "/",
        body_state: silly::RequestBody.Streamed,
        ..
    };
    match silly::body_view(streamed) {
        Failed failure => {
            assert(failure.error == silly::BodyError.Unavailable);
        },
        _ => {
            assert(false);
        },
    }
    let failed = silly::Request {
        method: "POST",
        target: "/",
        body_state: silly::RequestBody.Failed {
            error: silly::BodyError.InvalidFraming
        },
        ..
    };
    match silly::body_view(failed) {
        Failed failure => {
            assert(failure.error == silly::BodyError.InvalidFraming);
        },
        _ => {
            assert(false);
        },
    }
}

fn stale_output(response: silly::Response&) {
    response.output.append("stale");
    assert(silly::begin_response(response, 200) == silly::ResponseError.InvalidState);
    assert(response.output == "stale");
}

fn invalid_sink_capacity(response: silly::Response&) {
    assert(silly::begin_response(response, 200) == silly::ResponseError.None);
    assert(silly::append_body(response, "abcd") == silly::ResponseError.None);
    assert(silly::prepare_response(response) == silly::ResponseError.None);
    assert(silly::commit_response(response) == silly::ResponseError.None);
    var transport = silly::MemoryTransport {
        capacity: 4,
        ..
    };
    assert(silly::drain_memory(transport, response, 2) == silly::DrainResult.Progress);
    transport.capacity = 1;
    assert(silly::drain_memory(transport, response, 2) == silly::DrainResult.Failed);
    assert(transport.terminal_count == 1);
    assert(transport.bytes == "ab");
}

fn run() {
    with_response(silly::Limits {
        }, normal_handler);
    with_response(silly::Limits {
        }, empty_and_missing);
    with_response(silly::Limits {
        }, duplicate_and_commit);
    with_response(silly::Limits {
            output_bytes_max: 3,
            ..
        }, output_limit);
    with_response(silly::Limits {
            header_count_max: 1,
            ..
        }, header_count_limit);
    with_response(silly::Limits {
            header_bytes_max: 3,
            ..
        }, header_bytes_limit);
    with_response(silly::Limits {
        }, invalid_header);
    with_response(silly::Limits {
        }, invalid_status);
    with_response(silly::Limits {
            output_bytes_max: -1,
            ..
        }, invalid_limits);
    with_response(silly::Limits {
        }, partial_drain);
    with_response(silly::Limits {
        }, disconnect_drain);
    with_response(silly::Limits {
        }, custom_error);
    with_response(silly::Limits {
        }, stale_output);
    with_response(silly::Limits {
        }, invalid_sink_capacity);
    body_states();
    recover_failed_builder();
}

fn::main() {
    context_test::run();
    print("context contracts passed");
}
