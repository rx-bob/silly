// Selection transfers fixed owned state; input and writer slices remain callback-local.
namespace silly;

import.continuation;
import.stream;
import.stream_contract;

struct StreamOptions {
    content_type: const u8[:] = "application/octet-stream",
    pending_bytes_max: i64 = 4096,
}

fn stream<A, S>(ctx: Context<A, S> & , status: i32, state: S,
    options: StreamOptions = StreamOptions {
    }) -> ResponseError {
    if options.pending_bytes_max <= 0 || options.pending_bytes_max > CONTINUATION_CHUNK_BYTES {
        return ResponseError.InvalidLimits;
    }
    let sink = ctx.stream_start;
    guard sink else {
        return ResponseError.InvalidState;
    }
    if sink.selected {
        return ResponseError.AlreadyStarted;
    }
    let started = begin_response(ctx.response, status);
    if started != ResponseError.None {
        return started;
    }
    let metadata = add_header(ctx.response, "Content-Type", options.content_type);
    if metadata != ResponseError.None {
        return metadata;
    }
    var owned: S = default<S>();
    owned = state;
    sink.state = owned;
    sink.pending_bytes_max = options.pending_bytes_max;
    sink.selected = true;
    ctx.response.mode = ResponseBodyMode.Stream;
    return prepare_response(ctx.response);
}

// A streamed route lends input only to the producer, never to the handler body view.
fn stream_input<A, S>(ctx: Context<A, S> & , status: i32, state: S,
    options: StreamOptions = StreamOptions {
    }) -> ResponseError {
    if ctx.request.body_state != RequestBody.Streamed {
        return ResponseError.InvalidState;
    }
    let result = stream(ctx, status, state, options);
    let sink = ctx.stream_start;
    if result == ResponseError.None && sink {
        sink.input = true;
    }
    return result;
}
