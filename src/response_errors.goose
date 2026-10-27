// Precommit response failures are rendered into fresh bounded owners, without transport access.
namespace silly;

import.body_types;
import.http_head_types;
import.lifecycle_types;
import.response;
import.timeout_types;
import.transport;

enum ResponseFailureKind {
    None,
    MissingResponse,
    HandlerFailure,
    Serialization,
    RequestHead,
    RequestBody,
    Admission,
    Timeout,
}

struct ResponseFailure {
    timeout: TimeoutKind = TimeoutKind.None,
    kind: ResponseFailureKind = ResponseFailureKind.None,
    status: i32 = 500,
    error: ResponseError = ResponseError.None,
    head_error: HeadResult = HeadResult.Complete,
    body_error: BodyStatus = BodyStatus.Complete,
    transport_status: silly_transport::IoStatus = silly_transport::IoStatus.Ready,
    system_error: i32 = 0,
    error_policy: i64 = 0,
    method: u8[..32] = [],
    target: u8[..8192] = [],
    method_truncated: bool = false,
    target_truncated: bool = false,
    audit: AuditRecord = AuditRecord {
    },
}

fn default_response_error(response: Response&, failure: ResponseFailure) {
    if begin_response(response, failure.status) == ResponseError.None {
        prepare_response(response);
    }
}

fn response_failure(response: Response&, allow_stream: bool = false) -> ResponseFailure {
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
    } else if response.mode != ResponseBodyMode.Buffered && !allow_stream {
        // Only an owner with producer scheduling may accept a selected stream.
        failure.kind = ResponseFailureKind.Serialization;
        failure.error = ResponseError.InvalidState;
    }
    return failure;
}
