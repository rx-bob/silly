// Owned fixed-capacity completion records cross handler and transport lifetimes.
namespace silly;

import.context;
import.execution_types;
import.response;

struct Owner {
    id: i64 = 0,
    lane: i64 = -1,
}

// Numeric lane identity is available on Owner; named serialized registration arrives in E6.S3.
fn is_serialized(owner: Owner, lane: u8[:]) -> bool {
    return false;
}

enum HookResult {
    Ok,
    Failed {
        message: u8[..128]
    },
}
enum TransferOutcome {
    Pending,
    Delivered,
    Cancelled,
}
enum CompletionSelection {
    Unavailable,
    Matched,
    Generated,
    NotFound,
}
struct AuditRecord {
    request_id: u8[..128] = [],
    data: u8[..512] = [],
    request_payload: u8[..256] = [],
    response_payload: u8[..256] = [],
    request_truncated: bool = false,
    response_truncated: bool = false,
}
struct CompletionData {
    execution: ExecutionOutcome = ExecutionOutcome.None,
    route_id: i64 = -1,
    selection: CompletionSelection = CompletionSelection.Unavailable,
    method: u8[..32] = [],
    target: u8[..256] = [],
    method_truncated: bool = false,
    target_truncated: bool = false,
    status: i32 = 0,
    handler_ran: bool = false,
    handler_outcome: HandlerOutcome = HandlerOutcome.MissingResponse,
    transfer: TransferOutcome = TransferOutcome.Pending,
    wire_bytes: i64 = 0,
    system_error: i32 = 0,
    entered: u8 = 0,
    audit: AuditRecord = AuditRecord {
    },
}
enum CompletionRoute<R> {
    Unavailable,
    Application {
        route: R
    },
    Generated,
    NotFound,
}
struct Completion<R> {
    route: CompletionRoute<R>,
    data: CompletionData,
}
enum Lifecycle<R> {
    Start {
        owner: Owner
    },
    HandlerFinished {
        completion: Completion<R>
    },
    TransferFinished {
        completion: Completion<R>
    },
    Stop {
        owner: Owner
    },
}
// Server observers are static adapters; no callback value is stored in runtime options.
enum ServerEvent {
    Start,
    HandlerFinished {
        completion: CompletionData
    },
    TransferFinished {
        completion: CompletionData
    },
    Stop,
}
struct HookState {
    failure: HookResult = HookResult.Ok,
}
