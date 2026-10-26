// One invocation borrows request, response builders and execution-local application state.
namespace silly;

import.request;
import.response;

struct Context<A, S> {
    request: const Request&,
    response: Response&,
    app: A&,
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
