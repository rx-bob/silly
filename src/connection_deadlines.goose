// Monotonic phase deadlines are separate from transport activity and execution admission.
namespace silly;

import std;

import.connection;
import.server_options;

fn deadline_phase(phase: ConnectionPhase) -> ConnectionPhase {
    return if phase == ConnectionPhase.Continue {
        ConnectionPhase.ReadingBody
    } else {
        phase
    };
}

fn sync_connection_phase(connection: Connection&, now: i64) {
    let phase = deadline_phase(connection.phase);
    if connection.timed_phase != phase {
        connection.timed_phase = phase;
        connection.phase_started_ms = now;
    }
}

fn timeout_elapsed(now: i64, started: i64, budget: i64) -> bool {
    return now < started || now - started >= budget;
}

fn connection_timeout(connection: Connection&, options: ServerOptions, now: i64) -> TimeoutKind {
    if connection.phase == ConnectionPhase.Free {
        return TimeoutKind.None;
    }
    if connection.phase == ConnectionPhase.Executing && now >= connection.execution_deadline {
        return TimeoutKind.Execution;
    }
    if connection.phase == ConnectionPhase.Writing {
        return if timeout_elapsed(now, connection.active_ms, options.write_timeout_ms) {
            TimeoutKind.Write
        } else {
            TimeoutKind.None
        };
    }
    if connection.phase == ConnectionPhase.Reading && connection.input_bytes > 0
        && timeout_elapsed(now, connection.phase_started_ms, options.head_timeout_ms) {
        return TimeoutKind.Head;
    }
    if deadline_phase(connection.phase) == ConnectionPhase.ReadingBody
        && timeout_elapsed(now, connection.phase_started_ms, options.body_timeout_ms) {
        return TimeoutKind.Body;
    }
    // The absolute body budget wins when both interim-write and body clocks expire.
    if connection.phase == ConnectionPhase.Continue
        && timeout_elapsed(now, connection.active_ms, options.write_timeout_ms) {
        return TimeoutKind.Write;
    }
    return if timeout_elapsed(now, connection.active_ms, options.idle_timeout_ms) {
        TimeoutKind.Idle
    } else {
        TimeoutKind.None
    };
}

fn timeout_remaining(now: i64, started: i64, budget: i64) -> i64 {
    return if timeout_elapsed(now, started, budget) {
        0
    } else {
        budget - (now - started)
    };
}

fn connection_wait_ms(connection: Connection&, options: ServerOptions, now: i64) -> i64 {
    let poll: i64 = options.poll_timeout_ms;
    if connection.phase == ConnectionPhase.Free {
        return options.poll_timeout_ms;
    }
    if connection.phase == ConnectionPhase.Writing {
        return min(poll, timeout_remaining(now, connection.active_ms, options.write_timeout_ms));
    }
    var wait = min(poll, timeout_remaining(now, connection.active_ms, options.idle_timeout_ms));
    if connection.phase == ConnectionPhase.Reading && connection.input_bytes > 0 {
        wait = min(wait, timeout_remaining(now, connection.phase_started_ms, options.head_timeout_ms));
    }
    if deadline_phase(connection.phase) == ConnectionPhase.ReadingBody {
        wait = min(wait, timeout_remaining(now, connection.phase_started_ms, options.body_timeout_ms));
    }
    if connection.phase == ConnectionPhase.Continue {
        wait = min(wait, timeout_remaining(now, connection.active_ms, options.write_timeout_ms));
    }
    if connection.phase == ConnectionPhase.Executing {
        wait = min(wait, if now >= connection.execution_deadline {
                0
            } else {
                connection.execution_deadline - now
            });
    }
    return wait;
}
