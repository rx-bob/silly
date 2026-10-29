// Controlled clocks keep timer waits independent from newly offered output deadlines.
namespace stream_deadline_test;

import silly from "../../";

import std;

struct State {
    calls: i64 = 0,
    cancellations: i64 = 0,
    failure: bool = false,
}
struct App {
    completed: i64 = 0
}
enum Route {
    Stream
}
type Driver = silly::StreamDriver<Route, App, State>;

fn step(state: State&, event: silly::StreamEvent, out: silly::ChunkWriter&) -> silly::StreamStep {
    if event == silly::StreamEvent.Cancelled {
        state.cancellations += 1;
        return silly::StreamStep.Done;
    }
    state.calls += 1;
    if state.calls == 1 {
        return silly::StreamStep.Wait {
            wake: silly::Wake.After {
                delay_ms: 900
            }
        };
    }
    if state.failure {
        return silly::StreamStep.Failed {
            reason: silly::StreamError.Input
        };
    }
    assert(silly::append(out, "abc"));
    return silly::StreamStep.Chunk {
        flush: true,
        next: silly::Wake.Ready
    };
}

fn observe(driver: Driver&, event: silly::ServerEvent) -> silly::HookResult {
    match event {
        TransferFinished done => {
            assert(done.completion.transfer == silly::TransferOutcome.Cancelled);
            assert(done.completion.timeout == silly::TimeoutKind.Write);
            driver.lifecycle.app.completed += 1;
        },
        _ => {
            assert(false);
        },
    }
    return silly::HookResult.Ok;
}

fn timer_to_pending(failure: bool = false) {
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
    var slots: silly::StreamSlot<State>[1] = [silly::StreamSlot<State> {
        }];
    slots[0].active = true;
    slots[0].producer.continuation.state.failure = failure;
    slots[0].framing = silly::ResponseFraming.Chunked;
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
    var connection = silly::Connection {
        generation: 1,
        slot: 0,
        phase: silly::ConnectionPhase.Writing,
        head_bytes: 20,
        active_ms: 100,
        completion_pending: true,
        ..
    };
    connection.completion.method.append("GET");
    var hooks = silly::HookState {
    };
    var empty: u8[0] = [];
    var head: u8[512] = [0; 512];
    let buffers = silly::ConnectionBuffers {
        input: empty,
        head: head,
        body: empty,
        request: empty,
        staging: empty,
        hooks: hooks,
    };
    if failure {
        check_failure(driver, connection, buffers);
    } else {
        check_pending(driver, connection, buffers);
    }
}

fn check_pending(driver: Driver&, connection: silly::Connection&, buffers: silly::ConnectionBuffers) {
    let options = silly::ServerOptions {
        idle_timeout_ms: 2000,
        write_timeout_ms: 20,
        ..
    };
    let key = driver.slots[0].producer.continuation.key;
    assert(silly::stream_resume(driver.slots[0].producer, key, silly::StreamEvent.Ready, 100, step)
        == silly::ResumeResult.Applied);
    assert(silly::stream_timeout(driver.slots[0], connection, options, 999) == silly::TimeoutKind.None);
    silly::service_stream(driver, connection, buffers, options, 1000, 0, step, observe);
    assert(connection.active_ms == 1000);
    assert(silly::stream_pending_bytes(driver.slots[0].producer) == 3);
    assert(driver.slots[0].producer.continuation.state.calls == 2);
    assert(silly::stream_deadline(driver.slots[0], connection, options, 1019) == 1);
    silly::service_stream(driver, connection, buffers, options, 1019, 0, step, observe);
    assert(driver.slots[0].active);
    assert(driver.slots[0].producer.continuation.state.calls == 2);
    silly::service_stream(driver, connection, buffers, options, 1020, 0, step, observe);
    assert(!driver.slots[0].active);
    assert(connection.phase == silly::ConnectionPhase.Free);
    assert(driver.slots[0].producer.continuation.state.cancellations == 1);
    assert(driver.lifecycle.app.completed == 1);
    silly::cancel_stream_slot(driver.slots[0], step);
    assert(driver.slots[0].producer.continuation.state.cancellations == 1);
}

fn check_failure(driver: Driver&, connection: silly::Connection&, buffers: silly::ConnectionBuffers) {
    let options = silly::ServerOptions {
        idle_timeout_ms: 2000,
        write_timeout_ms: 20,
        ..
    };
    let key = driver.slots[0].producer.continuation.key;
    assert(silly::stream_resume(driver.slots[0].producer, key, silly::StreamEvent.Ready, 100, step)
        == silly::ResumeResult.Applied);
    silly::service_stream(driver, connection, buffers, options, 1000, 0, step, observe);
    assert(!driver.slots[0].active);
    assert(connection.active_ms == 1000);
    assert(connection.phase == silly::ConnectionPhase.Writing);
    assert(connection.completion.status == 500);
    assert(connection.head_bytes > 0);
    assert(starts_with(buffers.head[..connection.head_bytes], "HTTP/1.1 500 "));
    assert(connection.head_sent == 0);
    assert(driver.slots[0].producer.continuation.state.cancellations == 1);
    assert(driver.lifecycle.app.completed == 0);
    assert(silly::connection_timeout(connection, options, 1019) == silly::TimeoutKind.None);
    assert(silly::connection_timeout(connection, options, 1020) == silly::TimeoutKind.Write);
}

fn waiting_deadline() {
    var slot = silly::StreamSlot<State> {
    };
    var connection = silly::Connection {
        phase: silly::ConnectionPhase.Writing,
        active_ms: 100,
        ..
    };
    let options = silly::ServerOptions {
        idle_timeout_ms: 1000,
        write_timeout_ms: 20,
        ..
    };
    let key = slot.producer.continuation.key;
    assert(silly::stream_resume(slot.producer, key, silly::StreamEvent.Ready, 100, step)
        == silly::ResumeResult.Applied);
    assert(!silly::stream_wants_write(slot, connection));
    assert(silly::stream_timeout(slot, connection, options, 120) == silly::TimeoutKind.None);
    assert(silly::stream_deadline(slot, connection, options, 1099) == 1);
    assert(silly::stream_timeout(slot, connection, options, 1100) == silly::TimeoutKind.Idle);
    assert(silly::stream_timeout(slot, connection, options, 99) == silly::TimeoutKind.Idle);
    slot.ending = true;
    slot.producer.commit_requested = true;
    assert(silly::stream_timeout(slot, connection, options, 120) == silly::TimeoutKind.Write);
}

fn::main() {
    stream_deadline_test::waiting_deadline();
    stream_deadline_test::timer_to_pending();
    stream_deadline_test::timer_to_pending(true);
    print("stream timer idle and pending write deadlines passed");
}
