// Proxy admission selects an application-approved target and copies policy inputs before return.
namespace silly_client;

import silly from "..";

import.header_forwarding;
import.proxy_step;
import.proxy_target;
import.proxy_types;
import.request;
import.transport;
import.types;

fn proxy_response<A>(ctx: silly::Context<A, ProxyTransfer> & , options: ProxyOptions) -> silly::ResponseError {
    if options.inspection_bytes_max < 0 || options.inspection_bytes_max > 32768
        || options.poll_interval_ms < 1 || options.poll_interval_ms > 1000
        || options.pending_bytes_max < 1 || options.pending_bytes_max > 4096 {
        return silly::ResponseError.InvalidLimits;
    }
    let sink = ctx.stream_start;
    guard sink else {
        return silly::ResponseError.InvalidState;
    }
    if sink.selected {
        return silly::ResponseError.AlreadyStarted;
    }
    var forwarded = forward_request_headers(ctx.request, options.headers, ForwardPolicy {
            authorization: options.authorization,
            authorization_value: options.authorization_value,
            host: options.host,
            host_value: options.host_value,
            decoding: options.decoding,
        });
    var state = ProxyTransfer {
        tag: options.tag,
        poll_interval_ms: options.poll_interval_ms,
        inspection_bytes_max: options.inspection_bytes_max,
        ..
    };
    if ctx.request.method.len > state.method.cap {
        return silly::ResponseError.InvalidHeader;
    }
    state.method.append(ctx.request.method);
    if forwarded.error != ClientError.None {
        state.failure.error = forwarded.error;
    } else {
        var fields: RequestHeader[>..] = [];
        for index in forwarded.fields.len {
            fields.push(forward_header(forwarded, index));
        }
        state.failure.error = admit_proxy_request(state, ctx.request, options, fields);
    }
    let result = silly::start_stream(ctx, 200, state);
    if result != silly::ResponseError.None {
        abandon(state.upstream);
        return result;
    }
    sink.input = state.input_enabled;
    sink.defer_headers = true;
    sink.duplex = true;
    sink.pending_bytes_max = options.pending_bytes_max;
    return silly::ResponseError.None;
}

fn admit_proxy_request(state: ProxyTransfer&, request: silly::Request,
    options: ProxyOptions, fields: RequestHeader[:]) -> ClientError {
    var outgoing = RequestOptions {
        method: request.method,
        headers: fields,
        decoding: options.decoding,
        ..
    };
    match request.body_state {
        Buffered body => {
            if body.bytes.len > 0 {
                outgoing.body_mode = ClientBodyMode.Buffered;
                outgoing.body = body.bytes;
            }
        },
        Streamed => {
            if request.body_framing != silly::BodyFraming.None
                && !(request.body_framing == silly::BodyFraming.Fixed
                && silly::header(request, "Content-Length").value == "0") {
                outgoing.body_mode = ClientBodyMode.Stream;
                state.input_enabled = true;
                state.input_ended = false;
                state.upload_finished = false;
            }
        },
        Failed _ => {
            return ClientError.Invalid;
        },
    }
    let admitted = submit_request(options.client, options.target_url, outgoing);
    if admitted.ok {
        state.upstream = admitted.request;
    }
    return admitted.error;
}
