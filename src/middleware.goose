// Static before-chain under one endpoint; entered layers finish outside its guard boundary.
namespace silly;

import.audit;
import.context;
import.endpoint;
import.lifecycle_types;
import.response;

// Group/route selection stays in ordinary typed dispatch; callbacks are never runtime values.
fn middleware<A, S, R, G, M, B, H>(ctx: Context<A, S> & , route: R) {
    let sink .= audit_sink(ctx);
    if sink.entered != 0 {
        fail_response(ctx.response, ResponseError.InvalidState);
        reject(ctx);
    }
    sink.entered = 1;
    G(ctx, route);
    sink.entered = 3;
    M(ctx, route);
    sink.entered = 7;
    B(ctx, route);
    H(ctx, route);
}

// Both handler and transfer completions unwind route, group, global in reverse entry order.
// Hooks receive owned completion data and app state, never a writable response/context.
fn middleware_complete<A, R, G, M, B>(app: A&, event: Lifecycle<R>) -> HookResult {
    let entered = match event {
        HandlerFinished done => {
            done.completion.data.entered
        },
        TransferFinished done => {
            done.completion.data.entered
        },
        _ => {
            0
        },
    };
    var result = HookResult.Ok;
    if (entered & 4) != 0 {
        keep_hook_failure(result, B(app, event));
    }
    if (entered & 2) != 0 {
        keep_hook_failure(result, M(app, event));
    }
    if (entered & 1) != 0 {
        keep_hook_failure(result, G(app, event));
    }
    return result;
}

fn keep_hook_failure(result: HookResult&, next: HookResult) {
    if result == HookResult.Ok {
        result = next;
    }
}
