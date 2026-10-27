// Inline endpoints never construct snapshots. Lane endpoints transfer one bounded owned request.
namespace silly;

import std;

import.connection;
import.executor;
import.executor_types;
import.lifecycle_driver;
import.route_driver;
import.route_types;
import.runtime_control;
import.server_body;
import.state;
import.transport;

fn execution_status(outcome: ExecutionOutcome) -> i32 {
    return match outcome {
        InputLimit => 413,
        OutputLimit => 500,
        Deadline => 504,
        _ => 503,
    };
}

fn queue_execution(driver: NoState&, connection: Connection&, buffers: ConnectionBuffers) -> ExecutionOutcome {
    return ExecutionOutcome.Unavailable;
}

fn queue_execution<R>(driver: RoutePlan<R>&, connection: Connection&,
    buffers: ConnectionBuffers) -> ExecutionOutcome {
    return ExecutionOutcome.Unavailable;
}

fn queue_execution<R, A>(driver: RouteDriver<R, A> & , connection: Connection&,
    buffers: ConnectionBuffers) -> ExecutionOutcome {
    return ExecutionOutcome.Unavailable;
}

fn queue_execution<R, A>(driver: LifecycleDriver<R, A> & , connection: Connection&,
    buffers: ConnectionBuffers) -> ExecutionOutcome {
    let executor .= driver.executor;
    if connection.scan.head_bytes > executor.options.head_bytes_max
        || connection.request_bytes > executor.options.body_bytes_max {
        return ExecutionOutcome.InputLimit;
    }
    let clock = silly_transport::monotonic_ms();
    if clock.status != silly_transport::IoStatus.Ready
        || executor.options.task_timeout_ms > 0x7fffffffffffffff - clock.count {
        return ExecutionOutcome.Unavailable;
    }
    connection.execution_deadline = clock.count + executor.options.task_timeout_ms;
    let work = ExecWork {
        listener_id: connection.listener_id,
        key: TransferKey {
            owner: executor.owner,
            slot: connection.slot,
            connection_generation: connection.generation,
            request_generation: connection.request_generation,
        },
        lane: connection.execution_lane,
        deadline_ms: connection.execution_deadline,
        head: buffers.input[..connection.scan.head_bytes],
        body: buffers.request[..connection.request_bytes],
        completion: connection.completion,
        response_policy: connection.response_policy,
        close_after_reply: connection.close_after_reply,
    };
    return submit_executor(executor, work);
}

// While a task runs, preserve bounded pipelined input but never dispatch it early.
// When staging is full, suppress READ interest until the task finishes; HUP/error still cancel.
fn read_executing(connection: Connection&, staging: u8[:], events: i32, budget: i64) {
    if (events & (silly_transport::CLOSED | silly_transport::ERROR)) != 0 {
        release_connection(connection);
        return;
    }
    if (events & silly_transport::READ) == 0 {
        return;
    }
    if connection.staged_read > 0 {
        let remaining = connection.staged_bytes - connection.staged_read;
        for index in remaining {
            staging[index] = staging[index + connection.staged_read];
        }
        connection.staged_bytes = remaining;
        connection.staged_read = 0;
    }
    let cap = min(budget, staging.len - connection.staged_bytes);
    if cap <= 0 {
        return;
    }
    let result = silly_transport::read(connection.socket,
        staging[connection.staged_bytes..connection.staged_bytes + cap]);
    if result.status == silly_transport::IoStatus.Ready {
        connection.staged_bytes += result.count;
    } else if result.status != silly_transport::IoStatus.WouldBlock
        && result.status != silly_transport::IoStatus.Interrupted {
        connection.completion.system_error = result.error;
        release_connection(connection);
    }
}

fn driver_control_epoch(driver: NoState&) -> i64 {
    return 0;
}

fn driver_control_epoch<R>(driver: RoutePlan<R>&) -> i64 {
    return 0;
}

fn driver_control_epoch<R, A>(driver: RouteDriver<R, A> & ) -> i64 {
    return 0;
}

fn driver_control_epoch<R, A>(driver: LifecycleDriver<R, A> & ) -> i64 {
    return driver.control_epoch;
}

fn permit_inline(driver: NoState&) -> bool {
    return true;
}

fn permit_inline<R>(driver: RoutePlan<R>&) -> bool {
    return true;
}

fn permit_inline<R, A>(driver: RouteDriver<R, A> & ) -> bool {
    return true;
}

fn permit_inline<R, A>(driver: LifecycleDriver<R, A> & ) -> bool {
    // A lane acquired its admission permit before reconstructing the endpoint frame.
    return driver.owner.lane >= 0 || runtime_control_admit(driver.control_epoch);
}
