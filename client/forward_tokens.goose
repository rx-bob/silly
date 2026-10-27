// Connection-token parsing has independent byte and token budgets on both proxy legs.
namespace silly_client;

import std;

import.request;
import.types;

struct ConnectionToken {
    start: i64,
    length: i64,
}
struct ConnectionTokens {
    error: ClientError = ClientError.None,
    fields: ConnectionToken[..128] = [],
    bytes: u8[..4096] = [],
}

fn hop_header(name: u8[:]) -> bool {
    for blocked in["Connection", "Keep-Alive", "Proxy-Authenticate", "Proxy-Authorization",
        "TE", "Trailer", "Transfer-Encoding", "Upgrade", "Proxy-Connection", "Content-Length", "Expect"] {
        if request_name_equal(name, blocked) {
            return true;
        }
    }
    return false;
}

fn connection_tokens(headers: RequestHeader[:]) -> ConnectionTokens {
    var result = ConnectionTokens {
    };
    var total: i64 = 0;
    for header in headers {
        if !request_name_equal(header.name, "Connection") {
            continue;
        }
        if header.value.len > 4096 - total {
            result.error = ClientError.Limit;
            return result;
        }
        total += header.value.len;
        var at: i64 = 0;
        while at < header.value.len {
            var end = at;
            while end < header.value.len && header.value[end] != ',' {
                end += 1;
            }
            var first = at;
            var last = end;
            while first < last && (header.value[first] == ' ' || header.value[first] == '\t') {
                first += 1;
            }
            while last > first && (header.value[last - 1] == ' ' || header.value[last - 1] == '\t') {
                last -= 1;
            }
            if first != last {
                let name = header.value[first..last];
                if !request_token(name) {
                    result.error = ClientError.Invalid;
                    return result;
                }
                if result.fields.len == result.fields.cap {
                    result.error = ClientError.Limit;
                    return result;
                }
                result.fields.push(ConnectionToken {
                        start: result.bytes.len,
                        length: name.len
                    });
                result.bytes.append(name);
            }
            at = end + 1;
        }
    }
    return result;
}

fn connection_token(tokens: ConnectionTokens, name: u8[:]) -> bool {
    for field in tokens.fields {
        if request_name_equal(tokens.bytes[field.start..field.start + field.length], name) {
            return true;
        }
    }
    return false;
}
