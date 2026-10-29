// Deterministic bounded payload sink; HTTP wire framing belongs to E2.S3.
namespace silly;

import std;

enum DrainResult {
    Progress,
    Complete,
    Blocked,
    Failed,
    InvalidState,
}

struct MemoryTransport {
    capacity: i64,
    disconnected: bool = false,
    terminal_count: i64 = 0,
    bytes: u8[>..] = [],
}

fn drain_memory(transport: MemoryTransport&, response: Response&, allowance: i64) -> DrainResult {
    if response.phase != ResponsePhase.Committed || response.mode != ResponseBodyMode.Buffered {
        return DrainResult.InvalidState;
    }
    if transport.disconnected || transport.capacity < transport.bytes.len || allowance < 0 {
        if cancel_response(response, ResponseError.Transport) {
            transport.terminal_count += 1;
        }
        return DrainResult.Failed;
    }
    assert(response.sent_bytes >= 0);
    assert(response.sent_bytes <= response.output.len);
    let remaining = response.output.len - response.sent_bytes;
    let space = transport.capacity - transport.bytes.len;
    let count = min(remaining, min(space, allowance));
    if count > 0 {
        transport.bytes.append(response.output[response.sent_bytes..response.sent_bytes + count]);
        response.sent_bytes += count;
    }
    if complete_response(response) {
        transport.terminal_count += 1;
        return DrainResult.Complete;
    }
    if count == 0 {
        return DrainResult.Blocked;
    }
    return DrainResult.Progress;
}
