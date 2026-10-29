// Metadata completes before resource ownership moves into the scheduler's sink.
namespace silly;

import.continuation;

struct SseOptions {
    pending_bytes_max: i64 = CONTINUATION_CHUNK_BYTES,
    cache_control: const u8[:] = "no-cache",
}

fn events<A, S>(ctx: Context<A, S> & , state: S,
    options: SseOptions = SseOptions {
    }) -> ResponseError {
    if options.pending_bytes_max <= 0 || options.pending_bytes_max > CONTINUATION_CHUNK_BYTES {
        return ResponseError.InvalidLimits;
    }
    if !valid_header_value(options.cache_control) {
        return ResponseError.InvalidHeader;
    }
    let sink = ctx.stream_start;
    guard sink else {
        return ResponseError.InvalidState;
    }
    if sink.selected {
        return ResponseError.AlreadyStarted;
    }
    let started = begin_response(ctx.response, 200);
    if started != ResponseError.None {
        return started;
    }
    let content_type = add_header(ctx.response, "Content-Type", "text/event-stream");
    if content_type != ResponseError.None {
        return content_type;
    }
    let cache = add_header(ctx.response, "Cache-Control", options.cache_control);
    if cache != ResponseError.None {
        return cache;
    }
    let prepared = prepare_response(ctx.response);
    if prepared != ResponseError.None {
        return prepared;
    }
    var owned: S = default<S>();
    owned = state;
    sink.state = owned;
    sink.pending_bytes_max = options.pending_bytes_max;
    sink.input = false;
    sink.selected = true;
    ctx.response.mode = ResponseBodyMode.Stream;
    return ResponseError.None;
}
