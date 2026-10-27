// Precommit response failures are rendered into fresh bounded owners, without transport access.
namespace silly;

import.response;

enum ResponseFailureKind {
    None,
    MissingResponse,
    HandlerFailure,
    Serialization,
}

struct ResponseFailure {
    kind: ResponseFailureKind = ResponseFailureKind.None,
    status: i32 = 500,
    error: ResponseError = ResponseError.None,
}

fn default_response_error(response: Response&, failure: ResponseFailure) {
    if begin_response(response, failure.status) == ResponseError.None {
        prepare_response(response);
    }
}

fn response_failure(response: Response&) -> ResponseFailure {
    var failure = ResponseFailure {
    };
    if response.phase == ResponsePhase.Empty || response.phase == ResponsePhase.Preparing {
        failure.kind = ResponseFailureKind.MissingResponse;
        failure.error = ResponseError.MissingResponse;
    } else if response.phase != ResponsePhase.Prepared {
        failure.kind = ResponseFailureKind.HandlerFailure;
        failure.error = if response.error == ResponseError.None {
            ResponseError.InvalidState
        } else {
            response.error
        };
    } else if response.mode != ResponseBodyMode.Buffered {
        // Application stream scheduling is separate from the E2 wire-framing primitives.
        failure.kind = ResponseFailureKind.Serialization;
        failure.error = ResponseError.InvalidState;
    }
    return failure;
}
