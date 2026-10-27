// Proxy state owns only bounded metadata, one upload residual and optional explicitly capped inspection.
namespace silly_client;

import silly from "..";

import.header_forwarding;
import.request;
import.response;
import.types;

const EMPTY_PROXY_HEADERS: RequestHeader[0] = [];

struct ProxyOptions {
    client: Client,
    target_url: const u8[:],
    headers: const RequestHeader[:] = EMPTY_PROXY_HEADERS,
    authorization: ProxyAuthorization = ProxyAuthorization.None,
    authorization_value: const u8[:] = "",
    host: ProxyHost = ProxyHost.Target,
    host_value: const u8[:] = "",
    decoding: ContentDecoding = ContentDecoding.Raw,
    suppress_default_accept: bool = false,
    inspection_bytes_max: i64 = 0,
    poll_interval_ms: i64 = 1,
    pending_bytes_max: i64 = 4096,
    tag: u64 = 0,
}
struct ProxyFailure {
    error: ClientError,
    phase: ClientPhase = ClientPhase.Queue,
    tag: u64 = 0,
}
struct ProxyErrorResponse {
    status: i32 = 502,
    body: u8[..4096] = [],
    content_type: u8[..128] = [],
}
struct ProxyInspection {
    status_code: i32,
    tag: u64 = 0,
    decoded: bool = false,
    buffered: bool = false,
}
struct ProxyTransfer {
    upstream: ClientRequest = ClientRequest {
    },
    method: u8[..32] = [],
    tag: u64 = 0,
    poll_interval_ms: i64 = 1,
    inspection_bytes_max: i64 = 0,
    input_enabled: bool = false,
    input_ended: bool = true,
    upload_finished: bool = true,
    input: u8[..4096] = [],
    input_sent: i64 = 0,
    head: ClientResponse = ClientResponse {
    },
    head_ready: bool = false,
    published: bool = false,
    inspected: bool = false,
    failed: bool = false,
    done: bool = false,
    body: u8[..32768] = [],
    body_sent: i64 = 0,
    failure: ProxyFailure = ProxyFailure {
        error: ClientError.None,
        ..
    },
    error_response: ProxyErrorResponse = ProxyErrorResponse {
    },
}

fn default_proxy_error(failure: ProxyFailure) -> ProxyErrorResponse {
    return ProxyErrorResponse {
        status: if failure.error == ClientError.Timeout {
            504
        } else {
            502
        },
        ..
    };
}

fn default_proxy_inspect(info: ProxyInspection, head: ClientResponse&, body: u8[:]) -> i32 {
    return 0;
}
