// A published deferred head can still fail before the transport commits any bytes.
namespace proxy_failures;

import client from "../client";
import proxy from "../client";
import silly from "..";

import std;

fn map_failure(failure: silly_client::ProxyFailure) -> silly_client::ProxyErrorResponse {
    assert(failure.tag == 17);
    var result = silly_client::ProxyErrorResponse {
        status: 503,
        ..
    };
    result.body.append("mapped-before-wire");
    result.content_type.append("text/plain");
    return result;
}

fn forbidden_mapper(failure: silly_client::ProxyFailure) -> silly_client::ProxyErrorResponse {
    abort("failure mapper called after response commitment");
    return silly_client::ProxyErrorResponse {
    };
}

fn commitment() {
    var state = silly_client::ProxyTransfer {
        tag: 17,
        published: true,
        ..
    };
    state.failure.error = silly_client::ClientError.Reset;
    var fallback = silly::StreamFailureResponse {
    };
    var bytes: u8[1] = [0];
    // Pending output callbacks expose no writable bytes or metadata but own a fallback slot.
    var writer = silly::ChunkWriter {
        bytes: bytes[..0],
        failure: fallback,
        ..
    };
    let failed = silly_client::proxy_failure(state, writer, map_failure);
    assert_failed(failed);
    assert(fallback.selected);
    assert(fallback.status == 503);
    assert(fallback.body == "mapped-before-wire");
    assert(fallback.content_type == "text/plain");
    // Commitment removes the fallback pointer, so mapping cannot replace already emitted headers.
    writer.failure .= null;
    let closed = silly_client::proxy_failure(state, writer, forbidden_mapper);
    assert_failed(closed);
}

fn assert_failed(step: silly::StreamStep) {
    match step {
        Failed error => {
            assert(error.reason == silly::StreamError.Transport);
        },
        _ => {
            abort("proxy failure did not terminate");
        },
    }
}
