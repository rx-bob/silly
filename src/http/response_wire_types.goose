// Wire policy is separate from response owners and application payload bytes.
namespace silly;

enum ResponseFraming {
    None,
    Fixed,
    Chunked,
    Close,
}

struct ResponseWireOptions {
    http_minor: i32 = 1,
    request_method: const u8[:] = "GET",
    close: bool = true,
    representation_length: i64 = -1,
    stream_length: i64 = -1,
}

struct ResponseWirePlan {
    error: ResponseError = ResponseError.None,
    framing: ResponseFraming = ResponseFraming.None,
    content_length: i64 = -1,
    body_bytes: i64 = 0,
    informational: bool = false,
    close: bool = true,
}
