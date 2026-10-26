// Borrowed response builder. The driver separately owns fields, header bytes and output.
namespace silly;

import std;

import.headers;
import.limits;

enum ResponsePhase {
    Empty,
    Preparing,
    Prepared,
    Committed,
    Completed,
    Cancelled,
    Failed,
}

enum ResponseError {
    None,
    InvalidLimits,
    InvalidStatus,
    AlreadyStarted,
    InvalidState,
    OutputLimit,
    HeaderCountLimit,
    HeaderBytesLimit,
    InvalidHeader,
    MissingResponse,
    Transport,
    Application,
}

// Fields are coordinator internals: application mutation goes through checked operations.
// No retained source borrows handler-local bytes: append operations copy into these owners.
struct Response {
    limits: Limits,
    header_fields: HeaderField[>..]&,
    header_bytes: u8[>..]&,
    output: u8[>..]&,
    phase: ResponsePhase = ResponsePhase.Empty,
    status: i32 = 0,
    error: ResponseError = ResponseError.None,
    sent_bytes: i64 = 0,
}

fn begin_response(response: Response&, status: i32) -> ResponseError {
    if response.phase != ResponsePhase.Empty {
        return ResponseError.AlreadyStarted;
    }
    if response.header_fields.len != 0 || response.header_bytes.len != 0
        || response.output.len != 0 || response.sent_bytes != 0 {
        return fail_response(response, ResponseError.InvalidState);
    }
    if !valid(response.limits) {
        return fail_response(response, ResponseError.InvalidLimits);
    }
    if status < 200 || status > 599 {
        return fail_response(response, ResponseError.InvalidStatus);
    }
    response.status = status;
    response.phase = ResponsePhase.Preparing;
    return ResponseError.None;
}

fn append_body(response: Response&, bytes: u8[:]) -> ResponseError {
    if response.phase != ResponsePhase.Preparing {
        return ResponseError.InvalidState;
    }
    if response.output.len > response.limits.output_bytes_max
        || bytes.len > response.limits.output_bytes_max - response.output.len {
        return fail_response(response, ResponseError.OutputLimit);
    }
    response.output.append(bytes);
    return ResponseError.None;
}

fn add_header(response: Response&, name: u8[:], value: u8[:]) -> ResponseError {
    if response.phase != ResponsePhase.Preparing && response.phase != ResponsePhase.Prepared {
        return ResponseError.InvalidState;
    }
    let result = append_header(response.header_fields, response.header_bytes, name, value, HeaderLimits {
            count_max: response.limits.header_count_max,
            bytes_max: response.limits.header_bytes_max,
        });
    match result {
        Ok => {
            return ResponseError.None;
        },
        CountLimit => {
            return fail_response(response, ResponseError.HeaderCountLimit);
        },
        BytesLimit => {
            return fail_response(response, ResponseError.HeaderBytesLimit);
        },
        InvalidLimits => {
            return fail_response(response, ResponseError.InvalidLimits);
        },
        _ => {
            return fail_response(response, ResponseError.InvalidHeader);
        },
    }
}

fn set_status(response: Response&, status: i32) -> ResponseError {
    if response.phase != ResponsePhase.Preparing && response.phase != ResponsePhase.Prepared {
        return ResponseError.InvalidState;
    }
    if status < 200 || status > 599 {
        return fail_response(response, ResponseError.InvalidStatus);
    }
    response.status = status;
    return ResponseError.None;
}

fn prepare_response(response: Response&) -> ResponseError {
    if response.phase != ResponsePhase.Preparing {
        return ResponseError.InvalidState;
    }
    response.phase = ResponsePhase.Prepared;
    return ResponseError.None;
}

fn commit_response(response: Response&) -> ResponseError {
    if response.phase != ResponsePhase.Prepared {
        return ResponseError.InvalidState;
    }
    response.phase = ResponsePhase.Committed;
    return ResponseError.None;
}

// Returns false for repeated terminal calls; terminal cleanup belongs only to the true caller.
fn complete_response(response: Response&) -> bool {
    if response.phase != ResponsePhase.Committed || response.sent_bytes != response.output.len {
        return false;
    }
    response.phase = ResponsePhase.Completed;
    return true;
}

fn cancel_response(response: Response&, error: ResponseError) -> bool {
    if response.phase == ResponsePhase.Completed || response.phase == ResponsePhase.Cancelled {
        return false;
    }
    response.error = error;
    response.phase = ResponsePhase.Cancelled;
    return true;
}

fn fail_response(response: Response&, error: ResponseError) -> ResponseError {
    if response.phase == ResponsePhase.Committed {
        cancel_response(response, error);
    } else if response.phase != ResponsePhase.Completed && response.phase != ResponsePhase.Cancelled {
        response.error = error;
        response.phase = ResponsePhase.Failed;
    }
    return error;
}
