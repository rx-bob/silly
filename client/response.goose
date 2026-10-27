// Final response metadata owns bounded bytes and preserves ordered duplicate fields.
namespace silly_client;

import std;

import.decoding;
import.errors;
import.native;
import.request;
import.transport;
import.types;

enum ResponseKind {
    Final,
    Redirect,
    Bodyless
}
struct ResponseHeaderField {
    name_start: i64,
    name_bytes: i64,
    value_start: i64,
    value_bytes: i64,
}
struct ResponseHeaderView {
    name: const u8[:],
    value: const u8[:],
}
struct HeaderValue {
    present: bool = false,
    value: const u8[:] = ""
}
struct ClientResponse {
    ok: bool = true,
    ready: bool = false,
    error: ClientError = ClientError.None,
    status_code: i32 = 0,
    interim_count: i64 = 0,
    decoded: bool = false,
    bodyless: bool = false,
    kind: ResponseKind = ResponseKind.Final,
    fields: ResponseHeaderField[..128] = [],
    bytes: u8[..16384] = [],
}

fn redirect_status(status: i32) -> bool {
    return status == 301 || status == 302 || status == 303 || status == 307 || status == 308;
}

fn response(request: ClientRequest) -> ClientResponse {
    var facts: i64[4] = [0; 4];
    let result = silly_client_response(request.epoch, request.token, facts);
    if result < 0 {
        return response_error(client_error(-result));
    }
    if facts[0] == 0 {
        let pending = snapshot(request);
        if !pending.ok {
            return response_error(pending.error);
        }
        if pending.status == ClientStatus.Queued || pending.status == ClientStatus.Active {
            return ClientResponse {
                interim_count: facts[1],
                ..
            };
        }
        // Completion may have raced the first metadata snapshot. Recheck once after terminal status.
        let refreshed = silly_client_response(request.epoch, request.token, facts);
        if refreshed < 0 {
            return response_error(client_error(-refreshed));
        }
        if facts[0] == 0 {
            return response_error(if pending.error != ClientError.None {
                    pending.error
                } else {
                    ClientError.Protocol
                });
        }
    }
    var raw: u8[16384] = [0; 16384];
    let copied = headers(request, raw);
    if !copied.ok {
        return response_error(copied.error);
    }
    let state = snapshot(request);
    if !state.ok {
        return response_error(state.error);
    }
    var head = parse_client_response(raw[..copied.count], state.status_code, facts[2] != 0, facts[3] != 0);
    head.interim_count = facts[1];
    return head;
}

fn response_error(error: ClientError) -> ClientResponse {
    return ClientResponse {
        ok: false,
        error: error,
        ..
    };
}

fn response_header_value(value: u8[:]) -> bool {
    for byte in value {
        if (byte < 32 && byte != '\t') || byte == 127 {
            return false;
        }
    }
    return true;
}

fn append_response_field(head: ClientResponse&, line: u8[:], transfer_coded: bool) -> ClientError {
    let colon = find(line, ":");
    if colon <= 0 || !request_token(line[..colon]) {
        return ClientError.Protocol;
    }
    var start = colon + 1;
    var end = line.len;
    while start < end && (line[start] == ' ' || line[start] == '\t') {
        start += 1;
    }
    while end > start && (line[end - 1] == ' ' || line[end - 1] == '\t') {
        end -= 1;
    }
    let value = line[start..end];
    if !response_header_value(value) {
        return ClientError.Protocol;
    }
    if !decoded_response_field(line[..colon], head.decoded, head.bodyless, transfer_coded) {
        return ClientError.None;
    }
    if head.fields.len >= head.fields.cap || colon > head.bytes.cap - head.bytes.len
        || value.len > head.bytes.cap - head.bytes.len - colon {
        return ClientError.Limit;
    }
    head.fields.push(ResponseHeaderField {
            name_start: head.bytes.len,
            name_bytes: colon,
            value_start: head.bytes.len + colon,
            value_bytes: value.len,
        });
    head.bytes.append(line[..colon]);
    head.bytes.append(value);
    return ClientError.None;
}

fn response_status_line(line: u8[:], status: i32) -> bool {
    if line.len < 12 || (line[..9] != "HTTP/1.0 " && line[..9] != "HTTP/1.1 ") {
        return false;
    }
    if status < 200 || status > 599 {
        return false;
    }
    for index in 3 {
        if line[9 + index] < '0' || line[9 + index] > '9' {
            return false;
        }
    }
    let code = (line[9] - '0')as i32 * 100 + (line[10] - '0')as i32 * 10 + (line[11] - '0');
    return code == status && (line.len == 12 || line[12] == ' ') && response_header_value(line);
}

fn response_transfer_coded(raw: u8[:]) -> bool {
    var at: i64 = 0;
    while at < raw.len {
        let relative = find(raw[at..], "\r\n");
        if relative <= 0 {
            return false;
        }
        let line = raw[at..at + relative];
        let colon = find(line, ":");
        if colon > 0 && response_name_equal(line[..colon], "Transfer-Encoding") {
            return true;
        }
        at += relative + 2;
    }
    return false;
}

fn parse_client_response(raw: u8[:], status: i32, decoded: bool = false,
    bodyless: bool = false) -> ClientResponse {
    if raw.len > 16384 {
        return response_error(ClientError.Limit);
    }
    let first = find(raw, "\r\n");
    if first < 0 || !response_status_line(raw[..first], status) {
        return response_error(ClientError.Protocol);
    }
    var head = ClientResponse {
        ready: true,
        status_code: status,
        decoded: decoded,
        bodyless: bodyless,
        kind: if redirect_status(status) {
            ResponseKind.Redirect
        } else if bodyless {
            ResponseKind.Bodyless
        } else {
            ResponseKind.Final
        },
        ..
    };
    let transfer_coded = response_transfer_coded(raw);
    var at = first + 2;
    var count: i64 = 0;
    while at < raw.len {
        let relative = find(raw[at..], "\r\n");
        if relative < 0 {
            return response_error(ClientError.Protocol);
        }
        let end = at + relative;
        if end == at {
            return if end + 2 == raw.len {
                head
            } else {
                response_error(ClientError.Protocol)
            };
        }
        count += 1;
        if count > 128 {
            return response_error(ClientError.Limit);
        }
        let error = append_response_field(head, raw[at..end], transfer_coded);
        if error != ClientError.None {
            return response_error(error);
        }
        at = end + 2;
    }
    return response_error(ClientError.Protocol);
}

fn response_header(head: ClientResponse&, index: i64) -> ResponseHeaderView {
    assert(index >= 0);
    assert(index < head.fields.len);
    let field = head.fields[index];
    return ResponseHeaderView {
        name: head.bytes[field.name_start..field.name_start + field.name_bytes],
        value: head.bytes[field.value_start..field.value_start + field.value_bytes],
    };
}

fn get_header(head: ClientResponse&, name: u8[:]) -> HeaderValue {
    for index in head.fields.len {
        let field = response_header(head, index);
        if response_name_equal(field.name, name) {
            return HeaderValue {
                present: true,
                value: field.value
            };
        }
    }
    return HeaderValue {
    };
}

fn content_type(head: ClientResponse&) -> HeaderValue {
    return get_header(head, "Content-Type");
}
