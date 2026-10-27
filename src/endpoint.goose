// Named handler boundary catches terminal guards before coordinator cleanup runs.
namespace silly;

import.context;
import.response;

fn endpoint<A, S, R, H>(ctx: Context<A, S> & , route: R) {
    H(ctx, route);
}

// Cleanup is handler completion, not transport delivery; it runs outside the guard boundary.
fn coordinate_endpoint<A, S, R, H, C>(ctx: Context<A, S> & , route: R) -> HandlerOutcome {
    endpoint(ctx, route, H);
    let outcome = handler_outcome(ctx.response, RouteSelection.Matched);
    C(ctx.app, outcome);
    return outcome;
}

fn endpoint_cleanup<A>(app: A&, outcome: HandlerOutcome) {
}

// Local helpers return errors normally, so they remain legal outside an endpoint.
fn respond_text<A, S>(ctx: Context<A, S> & , status: i32, payload: u8[:]) -> ResponseError {
    let error = begin_response(ctx.response, status);
    if error != ResponseError.None {
        return fail_response(ctx.response, error);
    }
    let header = add_header(ctx.response, "Content-Type", "text/plain; charset=utf-8");
    if header != ResponseError.None {
        return header;
    }
    let body = append_body(ctx.response, payload);
    if body != ResponseError.None {
        return body;
    }
    return prepare_response(ctx.response);
}

fn respond_empty<A, S>(ctx: Context<A, S> & , status: i32) -> ResponseError {
    let error = begin_response(ctx.response, status);
    if error != ResponseError.None {
        return fail_response(ctx.response, error);
    }
    return prepare_response(ctx.response);
}

// Retain an application's already prepared response, including its exact error envelope.
fn reject<A, S>(ctx: Context<A, S> & ) {
    if ctx.response.phase != ResponsePhase.Prepared
        && ctx.response.phase != ResponsePhase.Failed && ctx.response.phase != ResponsePhase.Cancelled {
        fail_response(ctx.response, ResponseError.InvalidState);
    }
    return from silly::endpoint;
}

fn reject_text<A, S>(ctx: Context<A, S> & , status: i32, payload: u8[:]) {
    respond_text(ctx, status, payload);
    return from silly::endpoint;
}

fn reject_empty<A, S>(ctx: Context<A, S> & , status: i32) {
    respond_empty(ctx, status);
    return from silly::endpoint;
}
