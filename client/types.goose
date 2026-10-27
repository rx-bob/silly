// Epoch/token handles name native-owned resources; copies never transfer or duplicate ownership.
namespace silly_client;

enum ClientError {
    None,
    Invalid,
    Capacity,
    Unsupported,
    Dns,
    Connect,
    Tls,
    Timeout,
    Cancelled,
    Reset,
    Limit,
    Protocol,
    Internal,
    Stale,
    Busy,
    Decoding,
}
enum ClientStatus {
    Queued,
    Active,
    Complete,
    Failed
}
enum ClientPhase {
    Queue,
    Connect,
    Response,
    Body,
    Complete,
    Upload
}
struct ClientOptions {
    concurrency_max: i64 = 4,
    queue_max: i64 = 16,
    response_header_bytes_max: i64 = 16384,
    response_body_bytes_max: i64 = 64 * 1024 * 1024,
    queue_timeout_ms: i64 = 30000,
    connect_timeout_ms: i64 = 10000,
    first_byte_timeout_ms: i64 = 30000,
    idle_timeout_ms: i64 = 30000,
    total_timeout_ms: i64 = 0,
    poll_timeout_ms: i64 = 100,
    ca_file: const u8[:] = "",
    request_header_bytes_max: i64 = 16384,
    request_body_bytes_max: i64 = 64 * 1024 * 1024,
}
struct Client {
    epoch: i64 = 0
}
struct ClientRequest {
    epoch: i64 = 0,
    token: i64 = 0,
    redirect_hops: i64 = 0,
}
struct ClientStartResult {
    ok: bool,
    client: Client = Client {
    },
    error: ClientError = ClientError.None,
}
struct ClientSubmitResult {
    ok: bool,
    request: ClientRequest = ClientRequest {
    },
    error: ClientError = ClientError.None,
}
struct ClientOperation {
    ok: bool,
    error: ClientError = ClientError.None
}
struct ClientReadResult {
    ok: bool,
    count: i64 = 0,
    error: ClientError = ClientError.None,
}
struct ClientFinishResult {
    complete: bool,
    error: ClientError = ClientError.None
}
struct ClientSnapshot {
    ok: bool,
    status: ClientStatus = ClientStatus.Queued,
    error: ClientError = ClientError.None,
    phase: ClientPhase = ClientPhase.Queue,
    native_code: i64 = 0,
    status_code: i32 = 0,
    pending_bytes: i64 = 0,
    received_bytes: i64 = 0,
    new_connections: i64 = 0,
    pauses: i64 = 0,
}
