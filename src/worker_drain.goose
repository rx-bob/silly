// Drain leaves only already-admitted execution and buffered output; partial readers are cancelled.
namespace silly;

import.connection;
import.runtime_control;
import.server_executor;
import.server_loop;
import.server_observer;

fn worker_control_stage<D, O>(storage: ServerStorage&, driver: D&) -> i32 {
    let stage = runtime_control_stage(driver_control_epoch(driver));
    if stage != 1 {
        return stage;
    }
    for &connection in storage.connections {
        connection.draining = true;
        if connection.phase == ConnectionPhase.Free || connection.phase == ConnectionPhase.Executing
            || connection.phase == ConnectionPhase.Writing {
            continue;
        }
        release_connection(connection);
        finish_transfer(connection, driver, storage.hooks, TransferOutcome.Cancelled, O);
    }
    return stage;
}

fn worker_connections_empty(connections: Connection[:]) -> bool {
    for &connection in connections {
        if connection.phase != ConnectionPhase.Free {
            return false;
        }
    }
    return true;
}
