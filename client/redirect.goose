// Redirects never inherit headers or replay a body. Each target is an explicit application choice.
namespace silly_client;

import.errors;
import.native;
import.request;
import.response;
import.transport;
import.types;

// Resolve Location against the completed response URL without initiating a request.
fn redirect_url(request: ClientRequest, output: u8[:]) -> ClientReadResult {
    return client_read_result(silly_client_redirect_url(request.epoch, request.token, output));
}

fn follow_redirect(client: Client, parent: ClientRequest, approved_url: u8[:],
    options: RequestOptions = RequestOptions {
    }, max_hops: i64 = 5) -> ClientSubmitResult {
    if max_hops < 1 || max_hops > 16 || parent.redirect_hops < 0 || parent.redirect_hops >= max_hops {
        return ClientSubmitResult {
            ok: false,
            error: ClientError.Limit,
            ..
        };
    }
    let state = snapshot(parent);
    if !state.ok {
        return ClientSubmitResult {
            ok: false,
            error: state.error,
            ..
        };
    }
    if state.status != ClientStatus.Complete || !redirect_status(state.status_code) {
        return ClientSubmitResult {
            ok: false,
            error: ClientError.Invalid,
            ..
        };
    }
    var next = submit_request(client, approved_url, options);
    if next.ok {
        next.request.redirect_hops = parent.redirect_hops + 1;
    }
    return next;
}
