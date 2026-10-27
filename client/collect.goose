// Collection is an optional bounded consumer, never a mandatory payload envelope.
namespace silly_client;

import std;

import.transport;
import.types;

enum CollectStatus {
    Pending,
    Complete,
    Failed
}
struct ClientCollectResult {
    status: CollectStatus = CollectStatus.Pending,
    error: ClientError = ClientError.None,
    count: i64 = 0,
}

// Each call does at most work_bytes of copying. Call again on readiness or retained pending data.
fn collect(request: ClientRequest, out: u8[>..]&, limit: i64,
    work_bytes: i64 = 16384) -> ClientCollectResult {
    if limit < 0 || work_bytes < 1 || work_bytes > 16384 {
        return ClientCollectResult {
            status: CollectStatus.Failed,
            error: ClientError.Invalid,
            ..
        };
    }
    var result = ClientCollectResult {
    };
    var bytes: u8[4096] = [0; 4096];
    while result.count < work_bytes {
        let state = snapshot(request);
        if !state.ok || state.status == ClientStatus.Failed {
            return ClientCollectResult {
                status: CollectStatus.Failed,
                error: state.error,
                count: result.count
            };
        }
        if out.len > limit || state.pending_bytes > limit - out.len {
            cancel(request);
            return ClientCollectResult {
                status: CollectStatus.Failed,
                error: ClientError.Limit,
                count: result.count
            };
        }
        if state.pending_bytes == 0 {
            result.status = if state.status == ClientStatus.Complete {
                CollectStatus.Complete
            } else {
                CollectStatus.Pending
            };
            return result;
        }
        let count = min(state.pending_bytes, min(bytes.len, work_bytes - result.count));
        let copied = read(request, bytes[..count]);
        if !copied.ok {
            return ClientCollectResult {
                status: CollectStatus.Failed,
                error: copied.error,
                count: result.count
            };
        }
        if copied.count == 0 {
            return result;
        }
        out.append(bytes[..copied.count]);
        result.count += copied.count;
    }
    let state = snapshot(request);
    if !state.ok || state.status == ClientStatus.Failed {
        return ClientCollectResult {
            status: CollectStatus.Failed,
            error: state.error,
            count: result.count
        };
    }
    if state.status == ClientStatus.Complete && state.pending_bytes == 0 {
        result.status = CollectStatus.Complete;
    }
    return result;
}
