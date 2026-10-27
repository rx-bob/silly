// Input callbacks cannot erase expired deadlines or inherit a stale output deadline.
namespace stream_input_deadline_test;

import silly from "..";

import std;

struct State {
    inputs: i64 = 0,
    failures: i64 = 0,
    cancellations: i64 = 0,
}
struct App {
    transfers: i64 = 0,
}
enum Route {
    Echo
}
type Driver = silly::StreamDriver<Route, App, State>;

fn step(state: State&, event: silly::StreamEvent, out: silly::ChunkWriter&) -> silly::StreamStep {
    match event {
        Input piece => {
            state.inputs += 1;
            assert(silly::append(out, piece.bytes));
            return silly::StreamStep.Chunk {
                flush: true,
                next: silly::Wake.Input
            };
        },
        InputFailed _ => {
            state.failures += 1;
            return silly::StreamStep.Failed {
                reason: silly::StreamError.Input
            };
        },
        Cancelled => {
            state.cancellations += 1;
            return silly::StreamStep.Done;
        },
        _ => {
            assert(false);
        },
    }
    return silly::StreamStep.Done;
}

fn observe(driver: Driver&, event: silly::ServerEvent) -> silly::HookResult {
    driver.lifecycle.app.transfers += 1;
    return silly::HookResult.Ok;
}

fn initial_slot() -> silly::StreamSlot<State> {
    var slot = silly::StreamSlot<State> {
    };
    slot.active = true;
    slot.input_enabled = true;
    slot.input_started_ms = 100;
    slot.framing = silly::ResponseFraming.Chunked;
    slot.producer.continuation.phase = silly::ContinuationPhase.Waiting;
    slot.producer.continuation.wake = silly::Wake.Input;
    return slot;
}

fn initial_connection() -> silly::Connection {
    var connection = silly::Connection {
        generation: 1,
        slot: 0,
        phase: silly::ConnectionPhase.Writing,
        streamed_input: true,
        staged_bytes: 3,
        head_bytes: 20,
        active_ms: 100,
        completion_pending: true,
        ..
    };
    connection.reader = silly::new_body_reader(silly::BodyFraming.Fixed, 3, silly::BodyLimits {
        });
    connection.completion.method.append("POST");
    return connection;
}

fn exercise(kind: silly::TimeoutKind, closed: bool = false) {
    var app = App {
    };
    var entries: silly::RouteEntry<Route>[>..] = [];
    var segments: silly::RouteSegment[>..] = [];
    var bytes: u8[>..] = [];
    var router = silly::Router<Route> {
        entries: entries,
        segments: segments,
        bytes: bytes,
        ..
    };
    var slots: silly::StreamSlot<State>[1] = [initial_slot()];
    var driver = Driver {
        lifecycle: silly::LifecycleDriver<Route,
        App> {
            plan: silly::prepare(router),
            app: app,
            ..
        },
        slots: slots,
        ..
    };
    var pair = silly_transport::wake_pair();
    assert(pair.status == silly_transport::IoStatus.Ready);
    var connections: silly::Connection[1] = [initial_connection()];
    connections[0].socket = pair.writer;
    var hooks = silly::HookState {
    };
    var empty: u8[0] = [];
    var input: u8[128] = [0; 128];
    var head: u8[256] = [0; 256];
    var staging: u8[3] = ['a', 'b', 'c'];
    var fds: i32[3] = [-1; 3];
    var interests: i32[3] = [0; 3];
    var events: i32[3] = [0; 3];
    if closed {
        events[2] = silly_transport::CLOSED;
    }
    var storage = silly::ServerStorage {
        connections: connections,
        input: input,
        head: head,
        body: empty,
        request: empty,
        staging: staging,
        fds: fds,
        interests: interests,
        events: events,
        hooks: hooks,
        ..
    };
    var options = settings(kind);
    silly::service_active_stream(storage, options, driver, 1000, step, observe);
    check_result(storage, driver, options, kind);
    if closed {
        assert(connections[0].head_sent == 3);
    }
    silly_transport::close(pair.reader);
    silly_transport::close(pair.writer);
}

fn settings(kind: silly::TimeoutKind) -> silly::ServerOptions {
    return silly::ServerOptions {
        limits: silly::Limits {
            head_bytes_max: 128,
            body_bytes_max: 0,
            output_bytes_max: 0,
            ..
        },
        connections_max: 1,
        response_head_bytes_max: 256,
        work_bytes_per_turn: 3,
        idle_timeout_ms: if kind == silly::TimeoutKind.Idle {
            900
        } else {
            2000
        },
        body_timeout_ms: if kind == silly::TimeoutKind.Body {
            900
        } else {
            2000
        },
        write_timeout_ms: 20,
        body_read_bytes_max: 3,
        ..
    };
}

fn check_result(storage: silly::ServerStorage&, driver: Driver&,
    options: silly::ServerOptions, kind: silly::TimeoutKind) {
    let connection .= storage.connections[0];
    let slot .= driver.slots[0];
    assert(connection.active_ms == 1000);
    assert(driver.lifecycle.app.transfers == 0);
    if kind == silly::TimeoutKind.None {
        assert(slot.active);
        assert(slot.producer.continuation.state.inputs == 1);
        assert(slot.producer.continuation.state.failures == 0);
        assert(slot.producer.continuation.state.cancellations == 0);
        assert(silly::stream_pending_bytes(slot.producer) == 3);
        assert(connection.reader.status == silly::BodyStatus.Complete);
        assert(silly::stream_timeout(slot, connection, options, 1019) == silly::TimeoutKind.None);
        assert(silly::stream_timeout(slot, connection, options, 1020) == silly::TimeoutKind.Write);
    } else {
        assert(!slot.active);
        assert(slot.producer.continuation.state.inputs == 0);
        assert(slot.producer.continuation.state.failures == 1);
        assert(slot.producer.continuation.state.cancellations == 1);
        assert(connection.reader.decoded_bytes == 0);
        assert(connection.staged_read == 0);
        assert(connection.completion.timeout == kind);
        assert(connection.completion.status == 408);
        assert(connection.phase == silly::ConnectionPhase.Writing);
        assert(connection.head_sent == 0);
    }
}

fn::main() {
    stream_input_deadline_test::exercise(silly::TimeoutKind.None);
    stream_input_deadline_test::exercise(silly::TimeoutKind.None, true);
    stream_input_deadline_test::exercise(silly::TimeoutKind.Body);
    stream_input_deadline_test::exercise(silly::TimeoutKind.Idle);
    print("stream input respects expired deadlines and starts fresh output budgets");
}
