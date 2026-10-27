// Immutable metadata borrowing driver-owned request head and decoded body storage.
namespace silly;

import.header_index;
import.headers;
import.http_head_types;
import.limits;

const EMPTY_REQUEST_HEADERS: HeaderView[0] = [];

struct FieldValue {
    present: bool = false,
    value: const u8[:] = "",
}

enum BodyError {
    Unavailable,
    Limit,
    InvalidFraming,
    Disconnected,
}

enum RequestBody {
    Buffered {
        bytes: const u8[:]
    },
    Streamed,
    Failed {
        error: BodyError
    },
}

struct Request {
    method: const u8[:],
    target: const u8[:],
    headers: const HeaderView[:] = EMPTY_REQUEST_HEADERS,
    header_index: const HeaderIndexEntry[:] = EMPTY_HEADER_INDEX,
    body_framing: BodyFraming = BodyFraming.None,
    body_state: RequestBody = RequestBody.Buffered {
        bytes: ""
    },
}

enum BodyView {
    Available {
        bytes: const u8[:]
    },
    Failed {
        error: BodyError
    },
}

enum RequestError {
    None,
    InvalidLimits,
    HeadLimit,
    HeaderCountLimit,
    HeaderBytesLimit,
    InvalidHeader,
    BodyLimit,
    BodyFailed,
}

// The parser supplies the full retained head size, including separators and version bytes.
// This validates views/caps, not HTTP grammar; E2 owns parsing and framing validation.
fn validate_request(request: Request, head_bytes: i64, limits: Limits) -> RequestError {
    if !valid(limits) {
        return RequestError.InvalidLimits;
    }
    if head_bytes < 0 || head_bytes > limits.head_bytes_max {
        return RequestError.HeadLimit;
    }
    if request.headers.len > limits.header_count_max {
        return RequestError.HeaderCountLimit;
    }
    var remaining = limits.header_bytes_max;
    for field in request.headers {
        if field.name.len > remaining {
            return RequestError.HeaderBytesLimit;
        }
        remaining -= field.name.len;
        if field.value.len > remaining {
            return RequestError.HeaderBytesLimit;
        }
        remaining -= field.value.len;
        if !valid_header_name(field.name) || !valid_header_value(field.value) {
            return RequestError.InvalidHeader;
        }
    }
    match request.body_state {
        Buffered body => {
            if body.bytes.len > limits.body_bytes_max {
                return RequestError.BodyLimit;
            }
        },
        Failed _ => {
            return RequestError.BodyFailed;
        },
        Streamed => {
        },
    }
    return RequestError.None;
}

fn body_view(request: Request) -> BodyView {
    match request.body_state {
        Buffered body => {
            return BodyView.Available {
                bytes: body.bytes
            };
        },
        Streamed => {
            return BodyView.Failed {
                error: BodyError.Unavailable
            };
        },
        Failed failure => {
            return BodyView.Failed {
                error: failure.error
            };
        },
    }
}
