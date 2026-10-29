// Audit captures are explicit bounded copies; no request/response borrow enters completion.
namespace silly;

import std;

import.context;
import.endpoint;

fn audit_sink<A, S>(ctx: Context<A, S> & ) -> CompletionData& {
    let sink = ctx.audit;
    guard sink else {
        fail_response(ctx.response, ResponseError.InvalidState);
        reject(ctx);
    }
    return sink;
}

fn audit_request_id<A, S>(ctx: Context<A, S> & , value: u8[:]) {
    let sink .= audit_sink(ctx);
    if value.len > sink.audit.request_id.cap {
        fail_response(ctx.response, ResponseError.OutputLimit);
        reject(ctx);
    }
    sink.audit.request_id.clear();
    sink.audit.request_id.append(value);
}

// Application-selected metadata; its format and meaning remain application-owned.
fn audit_data<A, S>(ctx: Context<A, S> & , value: u8[:]) {
    let sink .= audit_sink(ctx);
    if value.len > sink.audit.data.cap {
        fail_response(ctx.response, ResponseError.OutputLimit);
        reject(ctx);
    }
    sink.audit.data.clear();
    sink.audit.data.append(value);
}

fn audit_request_payload<A, S>(ctx: Context<A, S> & , cap: i64) {
    let sink .= audit_sink(ctx);
    if cap < 0 || cap > sink.audit.request_payload.cap {
        fail_response(ctx.response, ResponseError.InvalidLimits);
        reject(ctx);
    }
    match body_view(ctx.request) {
        Available value => {
            sink.audit.request_payload.clear();
            sink.audit.request_payload.append(value.bytes[..min(cap, value.bytes.len)]);
            sink.audit.request_truncated = value.bytes.len > cap;
        },
        _ => {
            fail_response(ctx.response, ResponseError.InvalidState);
            reject(ctx);
        },
    }
}

// Captures only currently buffered bytes; never consumes or buffers a stream.
fn audit_response_payload<A, S>(ctx: Context<A, S> & , cap: i64) {
    let sink .= audit_sink(ctx);
    if cap < 0 || cap > sink.audit.response_payload.cap {
        fail_response(ctx.response, ResponseError.InvalidLimits);
        reject(ctx);
    }
    let bytes = ctx.response.output;
    sink.audit.response_payload.clear();
    sink.audit.response_payload.append(bytes[..min(cap, bytes.len)]);
    sink.audit.response_truncated = bytes.len > cap;
}
