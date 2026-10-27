// Source contract: mcp_settings/integration_routes.goose:289 and http_posix.c:242.
// Applications own configuration and scheduling; each poll drains at most 4096 bytes.
namespace promptnook_mcp;

import client from "../../client";

import std;

import.mcp_render;
import.mcp_url;

struct Check {
    request: silly_client::ClientRequest = silly_client::ClientRequest {
    },
    url: u8[..4096] = [],
    complete: bool = false,
    error: silly_client::ClientError = silly_client::ClientError.None,
    status: i32 = 0,
    detail: u8[..512] = [],
    received_bytes: i64 = 0,
}

fn client_options() -> silly_client::ClientOptions {
    return silly_client::ClientOptions {
        connect_timeout_ms: 2000,
        first_byte_timeout_ms: 4000,
        idle_timeout_ms: 2000,
        total_timeout_ms: 4000,
        ..
    };
}

fn begin_check(client: silly_client::Client, url: u8[:], token: u8[:] = "") -> Check {
    var check = Check {
    };
    if url.len > check.url.cap || token.len > 4096 {
        fail_check(check, silly_client::ClientError.Limit);
        return check;
    }
    let normalized = normalize_url(url);
    if !normalized.ok {
        fail_check(check, silly_client::ClientError.Invalid);
        return check;
    }
    check.url.append(normalized.value);
    let auth = str("Bearer ", token);
    var fields: silly_client::RequestHeader[>..] = [];
    fields.push(silly_client::RequestHeader {
            name: "Accept",
            value: "application/json, text/plain;q=0.9, */*;q=0.8"
        });
    if token.len > 0 {
        fields.push(silly_client::RequestHeader {
                name: "Authorization",
                value: auth
            });
    }
    let submitted = silly_client::submit_request(client, check.url, silly_client::RequestOptions {
            headers: fields,
            ..
        });
    if submitted.ok {
        check.request = submitted.request;
    } else {
        fail_check(check, submitted.error);
    }
    return check;
}

fn poll_check(check: Check&) -> bool {
    return poll_check_with(check, error_detail);
}

fn poll_check_with<F>(check: Check&) -> bool {
    if check.complete {
        return true;
    }
    let state = silly_client::snapshot(check.request);
    if !state.ok || state.status == silly_client::ClientStatus.Failed {
        fail_check_with(check, state.error, F);
        return true;
    }
    var bytes: u8[4096] = [0; 4096];
    let got = silly_client::read(check.request, bytes);
    if !got.ok {
        fail_check_with(check, got.error, F);
        return true;
    }
    check.received_bytes += got.count;
    if state.status != silly_client::ClientStatus.Complete || got.count != 0 {
        return false;
    }
    check.status = state.status_code;
    var raw: u8[16384] = [0; 16384];
    let head = silly_client::headers(check.request, raw);
    if !head.ok {
        fail_check_with(check, head.error, F);
        return true;
    }
    let reason = response_reason(raw[..head.count]);
    if reason.len > check.detail.cap {
        fail_check_with(check, silly_client::ClientError.Limit, F);
        return true;
    }
    check.detail.append(reason);
    check.complete = true;
    silly_client::abandon(check.request);
    return true;
}

fn response_reason(raw: u8[:]) -> const u8[:] {
    let end = find(raw, "\r\n");
    if end < 0 {
        return "";
    }
    let line = raw[..end];
    let first = find(line, " ");
    if first < 0 {
        return "";
    }
    let remaining = line[first + 1..];
    let second = find(remaining, " ");
    return if second < 0 {
        ""
    } else {
        remaining[second + 1..]
    };
}

fn fail_check(check: Check&, error: silly_client::ClientError) {
    fail_check_with(check, error, error_detail);
}

fn fail_check_with<F>(check: Check&, error: silly_client::ClientError) {
    silly_client::abandon(check.request);
    check.error = error;
    check.status = 0;
    check.complete = true;
    check.detail.clear();
    let detail = F(error);
    if detail.len <= check.detail.cap {
        check.detail.append(detail);
    } else {
        check.error = silly_client::ClientError.Limit;
        check.detail.append(error_detail(check.error));
    }
}

fn finish_check(check: Check&) {
    if !check.complete {
        fail_check(check, silly_client::ClientError.Cancelled);
    } else {
        silly_client::abandon(check.request);
    }
}
