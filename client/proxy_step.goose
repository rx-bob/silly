// Input and output make independent bounded progress; pending server output never blocks upload callbacks.
namespace silly_client;

import silly from "..";

import std;

import.proxy_metadata;
import.proxy_types;
import.request;
import.response;
import.transport;
import.types;

fn proxy_step(state: ProxyTransfer&, event: silly::StreamEvent, out: silly::ChunkWriter&) -> silly::StreamStep {
    return proxy_step_with_policy(state, event, out, default_proxy_error, default_proxy_inspect);
}

fn proxy_step_with_policy<F, I>(state: ProxyTransfer&, event: silly::StreamEvent,
    out: silly::ChunkWriter&) -> silly::StreamStep {
    if event == silly::StreamEvent.Cancelled {
        abandon(state.upstream);
        state.done = true;
        return silly::StreamStep.Done;
    }
    if !proxy_input(state, event) {
        abandon(state.upstream);
        return silly::StreamStep.Failed {
            reason: silly::StreamError.Input
        };
    }
    if state.failed {
        return proxy_error_step(state, out);
    }
    if state.failure.error != ClientError.None {
        return proxy_failure(state, out, F);
    }
    let upload = proxy_upload(state);
    if upload != ClientError.None {
        state.failure.error = upload;
        return proxy_failure(state, out, F);
    }
    // The first retained bytes are emitted before checking later upstream failures.
    if state.published && state.body_sent < state.body.len && out.bytes.len > 0 {
        return proxy_emit_owned(state, out);
    }
    let status = snapshot(state.upstream);
    if !status.ok || status.status == ClientStatus.Failed {
        state.failure.error = status.error;
        state.failure.phase = status.phase;
        return proxy_failure(state, out, F);
    }
    if !state.head_ready {
        state.head = response(state.upstream);
        if !state.head.ok {
            state.failure.error = state.head.error;
            return proxy_failure(state, out, F);
        }
        state.head_ready = state.head.ready;
    }
    if !state.head_ready || out.bytes.len == 0 {
        return proxy_wait(state);
    }
    if !state.published {
        return proxy_prepare(state, out, status, F, I);
    }
    let copied = read(state.upstream, out.bytes);
    if !copied.ok {
        state.failure.error = copied.error;
        return proxy_failure(state, out, F);
    }
    if copied.count > 0 {
        out.used = copied.count;
        return silly::StreamStep.Chunk {
            flush: false,
            next: proxy_wake(state)
        };
    }
    if status.status == ClientStatus.Complete {
        abandon(state.upstream);
        state.done = true;
        return silly::StreamStep.Done;
    }
    return proxy_wait(state);
}

fn proxy_input(state: ProxyTransfer&, event: silly::StreamEvent) -> bool {
    match event {
        Input chunk => {
            if !state.input_enabled || state.input_ended || state.input.len != 0 || chunk.bytes.len > state.input.cap {
                return false;
            }
            state.input.append(chunk.bytes);
        },
        InputEnd => {
            state.input_ended = true;
        },
        InputFailed _ => {
            return false;
        },
        _ => {
        },
    }
    return true;
}

fn proxy_upload(state: ProxyTransfer&) -> ClientError {
    if !state.input_enabled || state.upload_finished || state.upstream.token == 0 {
        return ClientError.None;
    }
    if state.input_sent < state.input.len {
        let copied = write_upload(state.upstream, state.input[state.input_sent..]);
        if !copied.ok {
            let status = snapshot(state.upstream);
            if status.ok && status.status == ClientStatus.Complete {
                state.upload_finished = true;
                state.input.clear();
                return ClientError.None;
            }
            state.failure.phase = status.phase;
            return copied.error;
        }
        state.input_sent += copied.count;
        if state.input_sent < state.input.len {
            return ClientError.None;
        }
        state.input.clear();
        state.input_sent = 0;
    }
    if state.input_ended {
        let ended = finish_upload(state.upstream);
        if !ended.ok {
            let status = snapshot(state.upstream);
            if !status.ok || status.status != ClientStatus.Complete {
                state.failure.phase = status.phase;
                return ended.error;
            }
        }
        state.upload_finished = true;
    }
    return ClientError.None;
}

fn proxy_wake(state: ProxyTransfer&) -> silly::Wake {
    if state.input_enabled && !state.input_ended && !state.upload_finished && state.input.len == 0 {
        return silly::Wake.InputAfter {
            delay_ms: state.poll_interval_ms
        };
    }
    return silly::Wake.After {
        delay_ms: state.poll_interval_ms
    };
}

fn proxy_wait(state: ProxyTransfer&) -> silly::StreamStep {
    return silly::StreamStep.Wait {
        wake: proxy_wake(state)
    };
}

fn proxy_emit_owned(state: ProxyTransfer&, out: silly::ChunkWriter&) -> silly::StreamStep {
    let count = min(out.bytes.len, state.body.len - state.body_sent);
    if count <= 0 {
        return proxy_wait(state);
    }
    if !silly::append(out, state.body[state.body_sent..state.body_sent + count]) {
        return silly::StreamStep.Failed {
            reason: silly::StreamError.OutputLimit
        };
    }
    state.body_sent += count;
    return silly::StreamStep.Chunk {
        flush: false,
        next: proxy_wake(state)
    };
}
