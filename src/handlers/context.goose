// One invocation borrows request, response builders and execution-local application state.
namespace silly;

struct Context<A, S> {
    request: const Request&,
    response: Response&,
    app: A&,
    stream_start: StreamStart<S>? = null,
    audit: CompletionData? = null,
    route_captures: RouteCaptures = RouteCaptures {
    },
}

fn param<A, S>(ctx: Context<A, S> & , name: u8[:]) -> FieldValue {
    return param(ctx.route_captures, name);
}

fn start_stream<A, S>(ctx: Context<A, S> & , status: i32, state: S) -> ResponseError {
    let pending = ctx.stream_start;
    guard pending else {
        return ResponseError.InvalidState;
    }
    if pending.selected {
        return ResponseError.AlreadyStarted;
    }
    let result = begin_response(ctx.response, status);
    if result != ResponseError.None {
        return result;
    }
    // default<S> enforces fixed-size S even when callers explicitly initialized the sink.
    var owned: S = default<S>();
    owned = state;
    pending.state = owned;
    pending.selected = true;
    ctx.response.mode = ResponseBodyMode.Stream;
    return prepare_response(ctx.response);
}

enum RouteSelection {
    Matched,
    NotFound,
}

enum HandlerOutcome {
    Prepared,
    RouteNotFound,
    MissingResponse,
    Failed {
        error: ResponseError
    },
}

fn header<A, S>(ctx: Context<A, S> & , name: u8[:]) -> FieldValue {
    return header(ctx.request, name);
}

fn header_raw<A, S>(ctx: Context<A, S> & , name: u8[:]) -> FieldValue {
    return header_raw(ctx.request, name);
}

fn header_wire<A, S>(ctx: Context<A, S> & , name: u8[:]) -> FieldValue {
    return header_wire(ctx.request, name);
}

fn header_values<A, S>(ctx: Context<A, S> & , name: u8[:],
    mode: HeaderValueMode = HeaderValueMode.Trimmed) -> HeaderValues {
    return header_values(ctx.request, name, mode);
}

fn body_view<A, S>(ctx: Context<A, S> & ) -> BodyView {
    return body_view(ctx.request);
}

fn handler_outcome(response: Response, selection: RouteSelection) -> HandlerOutcome {
    if response.phase == ResponsePhase.Failed || response.phase == ResponsePhase.Cancelled {
        return HandlerOutcome.Failed {
            error: response.error
        };
    }
    if response.phase == ResponsePhase.Prepared {
        return HandlerOutcome.Prepared;
    }
    if selection == RouteSelection.NotFound && response.phase == ResponsePhase.Empty {
        return HandlerOutcome.RouteNotFound;
    }
    if response.phase != ResponsePhase.Empty && response.phase != ResponsePhase.Preparing {
        return HandlerOutcome.Failed {
            error: ResponseError.InvalidState
        };
    }
    return HandlerOutcome.MissingResponse;
}

// Static application error conversion runs only on a fresh response owned by the coordinator.
// The coordinator must end failed-builder borrows and discard its buffers before this call.
fn convert_error<A, S, E, F>(ctx: Context<A, S> & , error: E) -> HandlerOutcome {
    if ctx.response.phase == ResponsePhase.Committed {
        cancel_response(ctx.response, ResponseError.Application);
        return HandlerOutcome.Failed {
            error: ResponseError.Application
        };
    }
    if ctx.response.phase != ResponsePhase.Empty {
        return HandlerOutcome.Failed {
            error: ResponseError.AlreadyStarted
        };
    }
    F(ctx, error);
    return handler_outcome(ctx.response, RouteSelection.Matched);
}
