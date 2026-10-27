// A lane reconstructs the complete endpoint frame inside its own snapshot owners.
namespace silly;

import std;

import.connection;
import.executor_types;
import.lifecycle_driver;
import.route_lifecycle;
import.server_body;
import.server_buffers;
import.server_observer;
import.worker_options;

struct LaneReply {
    key: TransferKey,
    outcome: ExecutionOutcome = ExecutionOutcome.Completed,
    head: u8[..16384] = [],
    body: u8[..65536] = [],
    completion: CompletionData = CompletionData {
    },
    close_after_reply: bool = true,
}

fn execute_lane_work<R, A, H, L, E>(start: LaneStart, work: ExecWork,
    driver: LifecycleDriver<R, A> & , hooks: HookState&) -> LaneReply {
    if !lane_work_matches(start, work, driver.plan) {
        return LaneReply {
            key: work.key,
            outcome: ExecutionOutcome.Unavailable,
            completion: work.completion,
            ..
        };
    }
    var options = worker_server_options(start.server);
    options.limits.head_bytes_max = start.options.head_bytes_max;
    options.limits.body_bytes_max = start.options.body_bytes_max;
    options.limits.output_bytes_max = start.options.response_body_bytes_max;
    options.response_head_bytes_max = start.options.response_head_bytes_max;
    var head: u8[16384] = [0; 16384];
    var body: u8[65536] = [0; 65536];
    var staging: u8[1] = [0];
    var connection = Connection {
        listener_id: work.listener_id,
        request_bytes: work.body.len,
        close_after_reply: work.close_after_reply,
        completion: work.completion,
        response_policy: work.response_policy,
        ..
    };
    connection.completion.execution = ExecutionOutcome.Completed;
    scan_head(connection.scan, work.head, options.limits);
    var input = work.head;
    var request = work.body;
    let buffers = ConnectionBuffers {
        input: input,
        head: head[..start.options.response_head_bytes_max],
        body: body[..start.options.response_body_bytes_max],
        request: request,
        staging: staging,
        hooks: hooks,
    };
    fn dispatch(state: LifecycleDriver<R, A> & , ctx: BufferedContext&) {
        dispatch_lifecycle_route(state, ctx, H);
        if ctx.response.error == ResponseError.OutputLimit || ctx.response.error == ResponseError.HeaderBytesLimit {
            let audit = ctx.audit;
            if audit {
                audit.execution = ExecutionOutcome.OutputLimit;
            }
        }
    }

    fn observe(state: LifecycleDriver<R, A> & , event: ServerEvent) -> HookResult {
        return observe_lifecycle(state, event, L);
    }
    let outcome = build_lane_response(connection, buffers, options, driver, dispatch, observe, E);
    return LaneReply {
        key: work.key,
        outcome: outcome,
        head: head[..connection.head_bytes],
        body: body[..connection.body_bytes],
        completion: connection.completion,
        close_after_reply: connection.close_after_reply,
    };
}

fn build_lane_response<D, H, O, E>(connection: Connection&, buffers: ConnectionBuffers,
    options: ServerOptions, driver: D&) -> ExecutionOutcome {
    var fields: HeaderView[>..] = [];
    var index: HeaderIndexEntry[>..] = [];
    let parsed = parse_head(buffers.input, fields, index, options.limits);
    if parsed.result != HeadResult.Complete {
        return ExecutionOutcome.InputLimit;
    }
    connection.http_minor = parsed.http_minor;
    let request = Request {
        listener_id: connection.listener_id,
        method: parsed.method,
        target: parsed.target,
        headers: fields,
        header_index: index,
        body_framing: parsed.framing,
        body_state: RequestBody.Buffered {
            bytes: buffers.request
        },
        ..
    };
    let wire = ResponseWireOptions {
        http_minor: parsed.http_minor,
        request_method: parsed.method,
        close: connection.close_after_reply,
        ..
    };
    let failure = application_reply(connection, buffers, options, request, wire, driver, H, O);
    if buffers.hooks.failure != HookResult.Ok {
        return ExecutionOutcome.Unavailable;
    }
    if failure.error != ResponseError.None {
        render_reply(connection, buffers, options, wire, failure, E);
    }
    return if failure.error == ResponseError.OutputLimit || failure.error == ResponseError.HeaderBytesLimit
        || failure.error == ResponseError.HeaderCountLimit {
        ExecutionOutcome.OutputLimit
    } else {
        ExecutionOutcome.Completed
    };
}

fn lane_work_matches<R>(start: LaneStart, work: ExecWork, plan: RoutePlan<R>) -> bool {
    var fields: HeaderView[>..] = [];
    var index: HeaderIndexEntry[>..] = [];
    let parsed = parse_head(work.head, fields, index, start.server.limits);
    if parsed.result != HeadResult.Complete {
        return false;
    }
    let selected = match_route(plan, parsed.method, parsed.target);
    if selected.result != RouteMatchResult.Matched || selected.route_id != work.completion.route_id {
        return false;
    }
    return match plan.entries[selected.route_id].options.execution {
        Inherit => false,
        Inline => false,
        Lane lane => lane.index == start.lane && work.lane == start.lane,
        Serialized selected => start.lane == 0 && work.lane == 0
            && selected.lane == start.options.serialized_name && valid_serialized_name(selected.lane),
    };
}
