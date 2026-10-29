// Only the addressed I/O owner consumes results; stale replies still release task credits.
namespace silly;

import std;

import.executor_types;
import.lifecycle_driver;
import.runtime_control;

fn drain_executor_results<Tag, E>(storage: ServerStorage&, options: ServerOptions, driver: NoState&, now: i64) -> bool {
    return false;
}

fn drain_executor_results<Tag, R, E>(storage: ServerStorage&, options: ServerOptions,
    driver: RoutePlan<R>&, now: i64) -> bool {
    return false;
}

fn drain_executor_results<Tag, R, A, E>(storage: ServerStorage&, options: ServerOptions,
    driver: RouteDriver<R, A> & , now: i64) -> bool {
    return false;
}

fn drain_executor_results<Tag, R, A, E>(storage: ServerStorage&, options: ServerOptions,
    driver: LifecycleDriver<R, A> & , now: i64) -> bool {
    if driver.executor.options.lanes == 0 {
        return false;
    }
    for index in options.dispatches_per_turn {
        let reply, present = qpoll<ExecReply<Tag>>();
        if !present {
            return false;
        }
        // Credits cover queued, active, and abandoned tasks, not merely live connection slots.
        if driver.executor.outstanding <= 0 {
            continue;
        }
        driver.executor.outstanding -= 1;
        apply_executor_reply(storage, options, driver.executor, reply, now, E);
    }
    return true;
}

fn execution_key(connection: Connection&, owner: i64) -> TransferKey {
    return TransferKey {
        owner: owner,
        slot: connection.slot,
        connection_generation: connection.generation,
        request_generation: connection.request_generation,
    };
}

fn apply_executor_reply<Tag, E>(storage: ServerStorage&, options: ServerOptions,
    owner: ExecutorOwner&, reply: ExecReply<Tag>, now: i64) -> bool {
    if reply.key.owner != owner.owner || reply.key.slot < 0 || reply.key.slot >= storage.connections.len {
        return false;
    }
    let connection .= storage.connections[reply.key.slot];
    if connection.phase != ConnectionPhase.Executing
        || !key_equal(execution_key(connection, owner.owner), reply.key) {
        return false;
    }
    let buffers = connection_buffers(storage, options, reply.key.slot);
    var outcome = reply.outcome;
    let fits = reply.head.len <= buffers.head.len && reply.body.len <= buffers.body.len;
    if !fits {
        outcome = ExecutionOutcome.OutputLimit;
    }
    if now >= connection.execution_deadline {
        outcome = ExecutionOutcome.Deadline;
    }
    if reply.head.len == 0 && outcome == ExecutionOutcome.Completed {
        outcome = ExecutionOutcome.Unavailable;
    }
    connection.completion = reply.completion;
    connection.completion.execution = outcome;
    if outcome == ExecutionOutcome.Deadline {
        connection.completion.timeout = TimeoutKind.Execution;
    }
    if outcome == ExecutionOutcome.Abandoned && owner.control_epoch > 0
        && runtime_control_stage(owner.control_epoch) != 0 {
        release_connection(connection);
        return true;
    }
    // A lane-rendered size error is already serialized; do not invoke its error renderer again on I/O.
    let rendered_error = outcome == ExecutionOutcome.OutputLimit && reply.outcome == outcome
        && reply.head.len > 0 && fits && now < connection.execution_deadline;
    if outcome != ExecutionOutcome.Completed && !rendered_error {
        request_error(connection, buffers, options, ResponseFailure {
                timeout: connection.completion.timeout,
                kind: if outcome == ExecutionOutcome.Deadline {
                    ResponseFailureKind.Timeout
                } else {
                    ResponseFailureKind.Admission
                },
                status: execution_status(outcome),
                ..
            }, E);
        return true;
    }
    copy_server_bytes(buffers.head, reply.head);
    copy_server_bytes(buffers.body, reply.body);
    connection.head_bytes = reply.head.len;
    connection.body_bytes = reply.body.len;
    connection.head_sent = 0;
    connection.body_sent = 0;
    connection.close_after_reply = reply.close_after_reply;
    connection.active_ms = now;
    connection.phase = ConnectionPhase.Writing;
    return true;
}
