// Request inputs are borrowed only during admission, then copied into bounded native storage.
namespace silly_client;

import std;

import.errors;
import.native;
import.transport;
import.types;

enum ClientBodyMode {
    None,
    Buffered,
    Stream
}
enum ContentDecoding {
    Raw,
    Automatic
}
struct RequestHeader {
    name: const u8[:],
    value: const u8[:]
}
struct RequestOptions {
    method: const u8[:] = "GET",
    headers: const RequestHeader[:] = [],
    body_mode: ClientBodyMode = ClientBodyMode.None,
    body: const u8[:] = "",
    body_length: i64 = -1,
    decoding: ContentDecoding = ContentDecoding.Raw,
}

fn request_token(value: u8[:]) -> bool {
    if value.len == 0 {
        return false;
    }
    for byte in value {
        if (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z')
            || (byte >= '0' && byte <= '9') {
            continue;
        }
        var punctuation = false;
        for allowed in "!#$%&'*+-.^_`|~" {
            if byte == allowed {
                punctuation = true;
            }
        }
        if !punctuation {
            return false;
        }
    }
    return true;
}

fn request_name_equal(left: u8[:], right: u8[:]) -> bool {
    if left.len != right.len {
        return false;
    }
    for index in left.len {
        let a = if left[index] >= 'A' && left[index] <= 'Z' {
            left[index] + 32
        } else {
            left[index]
        };
        let b = if right[index] >= 'A' && right[index] <= 'Z' {
            right[index] + 32
        } else {
            right[index]
        };
        if a != b {
            return false;
        }
    }
    return true;
}

fn request_header_valid(header: RequestHeader, decoding: ContentDecoding) -> bool {
    if !request_token(header.name) {
        return false;
    }
    for name in["Content-Length", "Transfer-Encoding", "Trailer", "Connection", "Expect", "Upgrade"] {
        if request_name_equal(header.name, name) {
            return false;
        }
    }
    if decoding == ContentDecoding.Automatic && request_name_equal(header.name, "Accept-Encoding") {
        return false;
    }
    for byte in header.value {
        if (byte < 32 && byte != '\t') || byte == 127 {
            return false;
        }
    }
    return true;
}

fn request_headers(out: u8[>..]&, options: RequestOptions) -> ClientError {
    if options.headers.len > 128 {
        return ClientError.Limit;
    }
    for header in options.headers {
        if !request_header_valid(header, options.decoding) {
            return ClientError.Invalid;
        }
        let available = 16384 - out.len;
        if available < 4 || header.name.len > available - 4
            || header.value.len > available - 4 - header.name.len {
            return ClientError.Limit;
        }
        out.append(header.name);
        out.append(": ");
        out.append(header.value);
        out.append("\r\n");
    }
    return ClientError.None;
}

fn submit_request(client: Client, url: u8[:], options: RequestOptions = RequestOptions {
    }) -> ClientSubmitResult {
    if options.method.len > 32 || !request_token(options.method) || options.body_length < - 1 {
        return ClientSubmitResult {
            ok: false,
            error: ClientError.Invalid,
            ..
        };
    }
    var headers: u8[>..] = [];
    let error = request_headers(headers, options);
    if error != ClientError.None {
        return ClientSubmitResult {
            ok: false,
            error: error,
            ..
        };
    }
    let mode: i64 = match options.body_mode {
        None => 0,
        Buffered => 1,
        Stream => 2,
    };
    let settings: i64[3] = [mode, options.body_length, if options.decoding == ContentDecoding.Automatic {
            1
        } else {
            0
        }];
    let result = silly_client_request(client.epoch, url, options.method, headers, options.body, settings);
    return ClientSubmitResult {
        ok: result > 0,
        request: ClientRequest {
            epoch: if result > 0 {
                client.epoch
            } else {
                0
            },
            token: if result > 0 {
                result
            } else {
                0
            },
            ..
        },
        error: if result < 0 {
            client_error(-result)
        } else {
            ClientError.None
        },
    };
}

// Partial acceptance is normal; zero means the bounded upload stage is currently full.
fn write_upload(request: ClientRequest, bytes: u8[:]) -> ClientReadResult {
    return client_read_result(silly_client_upload(request.epoch, request.token, bytes));
}

fn finish_upload(request: ClientRequest) -> ClientOperation {
    return client_operation(silly_client_upload_end(request.epoch, request.token));
}
