// Static lifecycle observation owns event data and never retains request or response views.
namespace silly;

import std;

import.connection;
import.execution_types;
import.http_head_types;
import.http_request_line;
import.lifecycle_types;
import.server_options;

fn no_server_observer<D>(driver: D&, event: ServerEvent) -> HookResult {
    return HookResult.Ok;
}

fn observe_server<D, O>(driver: D&, hooks: HookState&, event: ServerEvent) {
    let result = O(driver, event);
    if hooks.failure == HookResult.Ok && result != HookResult.Ok {
        hooks.failure = result;
    }
}

fn hook_server_result(hooks: HookState) -> ServerResult {
    return ServerResult {
        ok: false,
        error: ServerError.Hook,
        message: "lifecycle hook failed",
        hook_failure: hooks.failure,
        ..
    };
}

fn snapshot_request(connection: Connection&, input: u8[:]) {
    if connection.scan.request_line_end < 0 || connection.completion.method.len != 0 {
        return;
    }
    let line = parse_request_line(input[..connection.scan.request_line_end]);
    if line.result != HeadResult.Complete {
        return;
    }
    connection.completion.method.clear();
    connection.completion.method.append(line.method[..min(line.method.len, connection.completion.method.cap)]);
    connection.completion.method_truncated = line.method.len > connection.completion.method.cap;
    connection.completion.target.clear();
    connection.completion.target.append(line.target[..min(line.target.len, connection.completion.target.cap)]);
    connection.completion.target_truncated = line.target.len > connection.completion.target.cap;
}

// Clear before invoking user code: failures and subsequent shutdown cannot repeat a terminal event.
fn finish_transfer<D, O>(connection: Connection&, driver: D&, hooks: HookState&, outcome: TransferOutcome) {
    if !connection.completion_pending {
        return;
    }
    if connection.phase == ConnectionPhase.Executing && outcome == TransferOutcome.Cancelled {
        connection.completion.execution = ExecutionOutcome.Abandoned;
    }
    connection.completion_pending = false;
    connection.completion.transfer = outcome;
    observe_server(driver, hooks, ServerEvent.TransferFinished {
            completion: connection.completion,
        }, O);
}
