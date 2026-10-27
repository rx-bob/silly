// End-to-end headers are copied only after all Connection nominations have been collected.
namespace silly_client;

import silly from "..";

import std;

import.forward_tokens;
import.request;
import.response;
import.types;

enum ProxyAuthorization {
    None,
    Incoming,
    Override
}
enum ProxyHost {
    Target,
    Incoming,
    Override
}
struct ForwardPolicy {
    authorization: ProxyAuthorization = ProxyAuthorization.None,
    authorization_value: const u8[:] = "",
    host: ProxyHost = ProxyHost.Target,
    host_value: const u8[:] = "",
    decoding: ContentDecoding = ContentDecoding.Raw,
}
struct ForwardHeaders {
    error: ClientError = ClientError.None,
    fields: silly::HeaderField[..128] = [],
    bytes: u8[..16384] = [],
}

fn append_forward_header(out: ForwardHeaders&, name: u8[:], value: u8[:]) -> bool {
    if !request_token(name) || !silly::valid_header_value(value) {
        out.error = ClientError.Invalid;
        return false;
    }
    if out.fields.len == out.fields.cap || name.len > out.bytes.cap - out.bytes.len
        || value.len > out.bytes.cap - out.bytes.len - name.len {
        out.error = ClientError.Limit;
        return false;
    }
    out.fields.push(silly::HeaderField {
            name_start: out.bytes.len,
            name_bytes: name.len,
            value_start: out.bytes.len + name.len,
            value_bytes: value.len
        });
    out.bytes.append(name);
    out.bytes.append(value);
    return true;
}

fn forward_header(out: ForwardHeaders&, index: i64) -> RequestHeader {
    let field = silly::header_view(out.fields, out.bytes, index);
    return RequestHeader {
        name: field.name,
        value: field.value
    };
}

fn overridden(headers: RequestHeader[:], name: u8[:]) -> bool {
    for header in headers {
        if request_name_equal(header.name, name) {
            return true;
        }
    }
    return false;
}

fn forward_request_headers(request: const silly::Request&, overrides: RequestHeader[:],
    policy: ForwardPolicy = ForwardPolicy {
    }) -> ForwardHeaders {
    var out = ForwardHeaders {
    };
    if request.headers.len > 128 || overrides.len > 128 {
        out.error = ClientError.Limit;
        return out;
    }
    var incoming: RequestHeader[>..] = [];
    for field in request.headers {
        incoming.push(RequestHeader {
                name: field.name,
                value: field.value
            });
    }
    let tokens = connection_tokens(incoming);
    if tokens.error != ClientError.None {
        out.error = tokens.error;
        return out;
    }
    for header in overrides {
        if hop_header(header.name) || request_name_equal(header.name, "Authorization")
            || request_name_equal(header.name, "Host") || !request_header_valid(header, policy.decoding) {
            out.error = ClientError.Invalid;
            return out;
        }
    }
    var authorization_count: i64 = 0;
    for field in incoming {
        if hop_header(field.name) || connection_token(tokens, field.name) || overridden(overrides, field.name) {
            continue;
        }
        if request_name_equal(field.name, "Authorization") {
            if policy.authorization != ProxyAuthorization.Incoming {
                continue;
            }
            authorization_count += 1;
            if authorization_count > 1 {
                out.error = ClientError.Invalid;
                return out;
            }
        }
        if request_name_equal(field.name, "Host") && policy.host != ProxyHost.Incoming {
            continue;
        }
        if request_name_equal(field.name, "Accept-Encoding") && policy.decoding == ContentDecoding.Automatic {
            continue;
        }
        if !append_forward_header(out, field.name, field.value) {
            return out;
        }
    }
    for header in overrides {
        if !connection_token(tokens, header.name) && !append_forward_header(out, header.name, header.value) {
            return out;
        }
    }
    if policy.authorization == ProxyAuthorization.Override
        && !append_forward_header(out, "Authorization", policy.authorization_value) {
        return out;
    }
    if policy.host == ProxyHost.Override {
        if policy.host_value.len == 0 {
            out.error = ClientError.Invalid;
            return out;
        }
        append_forward_header(out, "Host", policy.host_value);
    }
    return out;
}

fn forward_response_headers(head: ClientResponse&) -> ForwardHeaders {
    var out = ForwardHeaders {
    };
    if !head.ok || !head.ready {
        out.error = if head.ok {
            ClientError.Invalid
        } else {
            head.error
        };
        return out;
    }
    var incoming: RequestHeader[>..] = [];
    for index in head.fields.len {
        let offsets = head.fields[index];
        if !silly::valid_response_offsets(silly::HeaderField {
                name_start: offsets.name_start,
                name_bytes: offsets.name_bytes,
                value_start: offsets.value_start,
                value_bytes: offsets.value_bytes
            }, head.bytes.len) {
            out.error = ClientError.Invalid;
            return out;
        }
        let field = response_header(head, index);
        incoming.push(RequestHeader {
                name: field.name,
                value: field.value
            });
    }
    let tokens = connection_tokens(incoming);
    if tokens.error != ClientError.None {
        out.error = tokens.error;
        return out;
    }
    for field in incoming {
        if !hop_header(field.name) && !connection_token(tokens, field.name)
            && !append_forward_header(out, field.name, field.value) {
            return out;
        }
    }
    return out;
}
