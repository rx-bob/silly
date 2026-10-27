// Deferred metadata uses the shared server writer; bounded inspection is an explicit application choice.
namespace silly_client;

import silly from "..";

import std;

import.forward_tokens;
import.header_forwarding;
import.proxy_step;
import.proxy_types;
import.request;
import.response;
import.transport;
import.types;

fn proxy_prepare<F, I>(state: ProxyTransfer&, out: silly::ChunkWriter&,
    status: ClientSnapshot) -> silly::StreamStep {
    if !state.head.bodyless && state.body.len < max(state.inspection_bytes_max, 4096) {
        var bytes: u8[4096] = [0; 4096];
        let cap = if state.inspection_bytes_max > 0 {
            state.inspection_bytes_max
        } else {
            4096
        };
        let copied = read(state.upstream, bytes[..min(bytes.len, cap - state.body.len)]);
        if !copied.ok {
            state.failure.error = copied.error;
            return proxy_failure(state, out, F);
        }
        state.body.append(bytes[..copied.count]);
    }
    let latest = snapshot(state.upstream);
    if !latest.ok || latest.status == ClientStatus.Failed {
        state.failure.error = latest.error;
        state.failure.phase = latest.phase;
        return proxy_failure(state, out, F);
    }
    if state.inspection_bytes_max > 0 && !state.head.bodyless {
        if latest.pending_bytes > state.inspection_bytes_max - state.body.len {
            state.failure.error = ClientError.Limit;
            return proxy_failure(state, out, F);
        }
        if latest.status != ClientStatus.Complete || latest.pending_bytes != 0 {
            return proxy_wait(state);
        }
    } else if state.body.len == 0 && !state.head.bodyless && latest.status != ClientStatus.Complete {
        return proxy_wait(state);
    }
    let inspected = I(ProxyInspection {
            status_code: state.head.status_code,
            tag: state.tag,
            decoded: state.head.decoded,
            buffered: state.inspection_bytes_max > 0,
        }, state.head, if state.inspection_bytes_max > 0 {
            state.body
        } else {
            ""
        });
    state.inspected = true;
    if inspected != 0 {
        state.head.status_code = inspected;
    }
    if state.head.status_code < 200 || state.head.status_code > 599 {
        state.failure.error = ClientError.Invalid;
        return proxy_failure(state, out, F);
    }
    let published = proxy_publish(state, out);
    if published != ClientError.None {
        state.failure.error = published;
        return proxy_failure(state, out, F);
    }
    state.published = true;
    return silly::StreamStep.Wait {
        wake: silly::Wake.Ready
    };
}

fn proxy_publish(state: ProxyTransfer&, out: silly::ChunkWriter&) -> ClientError {
    let metadata = out.metadata;
    guard metadata else {
        return ClientError.Invalid;
    }
    var forwarded = forward_response_headers(state.head);
    if forwarded.error != ClientError.None {
        return forwarded.error;
    }
    metadata.status = state.head.status_code;
    metadata.header_fields = forwarded.fields;
    metadata.header_bytes = forwarded.bytes;
    metadata.replace_headers = true;
    metadata.close = state.input_enabled && !state.input_ended;
    metadata.representation_length = -1;
    if state.method == "HEAD" || state.head.status_code == 304 {
        metadata.representation_length = proxy_representation_length(state.head);
    } else if state.inspection_bytes_max > 0 && state.head.status_code != 204 && state.head.status_code != 205 {
        metadata.representation_length = state.body.len;
    }
    metadata.ready = true;
    return ClientError.None;
}

fn proxy_representation_length(head: ClientResponse&) -> i64 {
    var headers: RequestHeader[>..] = [];
    var lengths: i64 = 0;
    for index in head.fields.len {
        let field = response_header(head, index);
        headers.push(RequestHeader {
                name: field.name,
                value: field.value
            });
        if request_name_equal(field.name, "Content-Length") {
            lengths += 1;
        }
    }
    let tokens = connection_tokens(headers);
    if lengths != 1 || tokens.error != ClientError.None || connection_token(tokens, "Content-Length") {
        return -1;
    }
    let value = get_header(head, "Content-Length");
    if !value.present || value.value.len == 0 {
        return -1;
    }
    var length: i64 = 0;
    for byte in value.value {
        if byte < '0' || byte > '9' {
            return -1;
        }
        let digit = (byte - '0')as i64;
        if length > (9223372036854775807 - digit) / 10 {
            return -1;
        }
        length = length * 10 + digit;
    }
    return length;
}

fn proxy_failure<F>(state: ProxyTransfer&, out: silly::ChunkWriter&) -> silly::StreamStep {
    abandon(state.upstream);
    if state.published {
        let fallback = out.failure;
        if fallback {
            state.failure.tag = state.tag;
            let mapped = F(state.failure);
            fallback.selected = true;
            fallback.status = if mapped.status >= 200 && mapped.status <= 599 {
                mapped.status
            } else {
                500
            };
            fallback.body = mapped.body;
            fallback.content_type = mapped.content_type;
        }
        return silly::StreamStep.Failed {
            reason: silly::StreamError.Transport
        };
    }
    state.failure.tag = state.tag;
    state.error_response = F(state.failure);
    if state.error_response.status < 200 || state.error_response.status > 599 {
        state.error_response = ProxyErrorResponse {
            status: 500,
            ..
        };
    }
    state.failed = true;
    state.input.clear();
    state.input_enabled = false;
    return proxy_error_step(state, out);
}

fn proxy_error_step(state: ProxyTransfer&, out: silly::ChunkWriter&) -> silly::StreamStep {
    if !state.published {
        let metadata = out.metadata;
        guard metadata else {
            return silly::StreamStep.Failed {
                reason: silly::StreamError.InvalidStep
            };
        }
        metadata.status = state.error_response.status;
        metadata.content_type = state.error_response.content_type;
        metadata.replace_headers = true;
        metadata.close = !state.input_ended;
        metadata.representation_length = if state.error_response.status == 204 || state.error_response.status == 205 {
            -1
        } else {
            state.error_response.body.len
        };
        metadata.ready = true;
        state.published = true;
        state.body.clear();
        state.body.append(state.error_response.body);
        state.body_sent = 0;
        return silly::StreamStep.Wait {
            wake: silly::Wake.Ready
        };
    }
    if state.body_sent < state.body.len {
        return proxy_emit_owned(state, out);
    }
    return if out.bytes.len == 0 {
        proxy_wait(state)
    } else {
        silly::StreamStep.Done
    };
}
