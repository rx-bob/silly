// Copied lane inputs and addressed output snapshots contain no borrowed application storage.
namespace silly;

import.execution_types;
import.lifecycle_types;
import.worker_options;

struct ExecutorOptions {
    serialized_name: u8[..64] = [],
    lanes: i64 = 0,
    independent_lanes: bool = false,
    queue_max: i64 = 8,
    outstanding_per_owner: i64 = 8,
    head_bytes_max: i64 = 16384,
    body_bytes_max: i64 = 65536,
    response_head_bytes_max: i64 = 16384,
    response_body_bytes_max: i64 = 65536,
    task_timeout_ms: i64 = 30000,
}
struct ExecWork {
    listener_id: i64 = 0,
    key: TransferKey,
    lane: i64,
    deadline_ms: i64,
    head: u8[..16384] = [],
    body: u8[..65536] = [],
    completion: CompletionData = CompletionData {
    },
    response_policy: ResponsePolicyState = ResponsePolicyState {
    },
    close_after_reply: bool = true,
}
struct ExecReply<Tag> {
    key: TransferKey,
    outcome: ExecutionOutcome = ExecutionOutcome.Completed,
    head: u8[..16384] = [],
    body: u8[..65536] = [],
    completion: CompletionData = CompletionData {
    },
    close_after_reply: bool = true,
}
struct ExecutorLane0 {
}
struct ExecutorLane1 {
}
struct ExecutorLane2 {
}
struct ExecutorLane3 {
}
struct LaneTask<Tag> {
    work: ExecWork
}
struct LaneStop<Tag> {
    stop: bool = true
}
struct ExecutorOwner {
    control_epoch: i64 = 0,
    options: ExecutorOptions = ExecutorOptions {
    },
    owner: i64 = -1,
    lane_writers: i32[4] = [-1; 4],
    outstanding: i64 = 0,
}
struct LaneStart {
    control_epoch: i64 = 0,
    options: ExecutorOptions,
    server: WorkerOptions,
    lane: i64,
    wake: i32,
    owner_writers: i32[4],
    report_wake: i32,
}
struct ExecutorReport {
    lane: i64,
    ready: bool = false,
    ok: bool,
    error: ServerError = ServerError.None,
    route_issue: RouteIssue = RouteIssue {
    },
    hook_failure: HookResult = HookResult.Ok,
}
fn valid_executor_options(options: ExecutorOptions) -> bool {
    return (options.serialized_name.len == 0
        || (options.lanes > 0 && valid_serialized_name(options.serialized_name)))
        && options.lanes >= 0 && options.lanes <= 4
        && (options.lanes <= 1 || options.independent_lanes)
        && options.queue_max > 0 && options.queue_max <= 1024
        && options.outstanding_per_owner > 0 && options.outstanding_per_owner <= 1024
        && options.head_bytes_max > 0 && options.head_bytes_max <= 16384
        && options.body_bytes_max >= 0 && options.body_bytes_max <= 65536
        && options.response_head_bytes_max >= 128 && options.response_head_bytes_max <= 16384
        && options.response_body_bytes_max >= 0 && options.response_body_bytes_max <= 65536
        && options.task_timeout_ms > 0;
}
