// Controlled monotonic clocks prove independent phase and activity budgets without sleeps.
namespace phase_timeout_test;

import silly from "..";

import std;

fn head_and_body() {
    let options = silly::ServerOptions {
        idle_timeout_ms: 1000,
        head_timeout_ms: 20,
        body_timeout_ms: 30,
        write_timeout_ms: 40,
        poll_timeout_ms: 100,
        ..
    };
    var connection = silly::Connection {
        phase: silly::ConnectionPhase.Reading,
        input_bytes: 1,
        active_ms: 119,
        phase_started_ms: 100,
        timed_phase: silly::ConnectionPhase.Reading,
        ..
    };
    assert(silly::connection_timeout(connection, options, 119) == silly::TimeoutKind.None);
    assert(silly::connection_wait_ms(connection, options, 119) == 1);
    assert(silly::connection_timeout(connection, options, 120) == silly::TimeoutKind.Head);
    connection.phase = silly::ConnectionPhase.ReadingBody;
    silly::sync_connection_phase(connection, 120);
    assert(connection.phase_started_ms == 120);
    connection.phase = silly::ConnectionPhase.Continue;
    silly::sync_connection_phase(connection, 125);
    assert(connection.phase_started_ms == 120);
    connection.phase = silly::ConnectionPhase.ReadingBody;
    connection.active_ms = 149;
    silly::sync_connection_phase(connection, 149);
    assert(silly::connection_wait_ms(connection, options, 149) == 1);
    assert(silly::connection_timeout(connection, options, 150) == silly::TimeoutKind.Body);
}

fn activity_and_execution() {
    let options = silly::ServerOptions {
        idle_timeout_ms: 10,
        write_timeout_ms: 40,
        poll_timeout_ms: 10,
        ..
    };
    var connection = silly::Connection {
        phase: silly::ConnectionPhase.Writing,
        active_ms: 100,
        ..
    };
    assert(silly::connection_timeout(connection, options, 120) == silly::TimeoutKind.None);
    assert(silly::connection_timeout(connection, options, 140) == silly::TimeoutKind.Write);
    connection.active_ms = 135;
    assert(silly::connection_timeout(connection, options, 140) == silly::TimeoutKind.None);
    connection.phase = silly::ConnectionPhase.Reading;
    assert(silly::connection_timeout(connection, options, 145) == silly::TimeoutKind.Idle);
    connection.phase = silly::ConnectionPhase.Executing;
    connection.execution_deadline = 142;
    assert(silly::connection_timeout(connection, options, 142) == silly::TimeoutKind.Execution);
    assert(silly::connection_wait_ms(connection, options, 142) == 0);
    connection.phase = silly::ConnectionPhase.Free;
    assert(silly::connection_timeout(connection, options, 999) == silly::TimeoutKind.None);
    connection.phase = silly::ConnectionPhase.Writing;
    assert(silly::connection_timeout(connection, options, 134) == silly::TimeoutKind.Write);
}

fn interim_write() {
    let options = silly::ServerOptions {
        idle_timeout_ms: 1000,
        body_timeout_ms: 100,
        write_timeout_ms: 20,
        ..
    };
    var connection = silly::Connection {
        phase: silly::ConnectionPhase.Continue,
        active_ms: 100,
        phase_started_ms: 100,
        timed_phase: silly::ConnectionPhase.ReadingBody,
        ..
    };
    assert(silly::connection_wait_ms(connection, options, 119) == 1);
    assert(silly::connection_timeout(connection, options, 120) == silly::TimeoutKind.Write);
    assert(silly::connection_timeout(connection, options, 200) == silly::TimeoutKind.Body);
}

fn::main() {
    phase_timeout_test::head_and_body();
    phase_timeout_test::activity_and_execution();
    phase_timeout_test::interim_write();
    var options = silly::ServerOptions {
    };
    options.head_timeout_ms = 0;
    assert(!silly::valid_server_options(options));
    options.head_timeout_ms = 1;
    options.body_timeout_ms = 0;
    assert(!silly::valid_server_options(options));
    options.body_timeout_ms = 1;
    options.write_timeout_ms = 0;
    assert(!silly::valid_server_options(options));
}
