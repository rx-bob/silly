// Duplex callbacks retain downstream ownership while upload and timers advance.
namespace stream_duplex_test;

import silly from "..";

import std;

struct State {
    calls: i64 = 0,
    inputs: i64 = 0,
    ends: i64 = 0,
    cancelled: i64 = 0,
    invalid: bool = false,
    delay: i64 = 10,
}

fn step(state: State&, event: silly::StreamEvent, out: silly::ChunkWriter&) -> silly::StreamStep {
    if event == silly::StreamEvent.Cancelled {
        state.cancelled += 1;
        return silly::StreamStep.Done;
    }
    state.calls += 1;
    if state.calls == 1 {
        assert(silly::append(out, "abc"));
        return silly::StreamStep.Chunk {
            flush: true,
            next: silly::Wake.InputAfter {
                delay_ms: state.delay
            },
        };
    }
    assert(out.bytes.len == 0);
    assert(out.metadata == null);
    assert(!silly::append(out, "x"));
    match event {
        Input input => {
            state.inputs += input.bytes.len;
        },
        InputEnd => {
            state.ends += 1;
        },
        InputFailed failure => {
            let mapped = out.failure;
            if mapped {
                mapped.selected = true;
                mapped.status = 503;
                mapped.body.append("mapped precommit");
            }
            return silly::StreamStep.Failed {
                reason: failure.reason
            };
        },
        _ => {
        },
    }
    if state.invalid {
        return silly::StreamStep.Done;
    }
    return silly::StreamStep.Wait {
        wake: silly::Wake.InputAfter {
            delay_ms: state.delay
        },
    };
}

fn producer(duplex: bool = true) -> silly::StreamProducer<State> {
    return silly::StreamProducer<State> {
        continuation: silly::Continuation<State> {
            key: silly::TransferKey {
                owner: 0,
                slot: 0,
                connection_generation: 1,
                request_generation: 1,
            },
            state: State {
            },
            ..
        },
        duplex: duplex,
        ..
    };
}

fn pending_progress() {
    var p = producer();
    let key = p.continuation.key;
    assert(silly::stream_resume(p, key, silly::StreamEvent.Ready, 100, step) == silly::ResumeResult.Applied);
    assert(silly::stream_acknowledge(p, key, 1) == silly::ResumeResult.Applied);
    assert(silly::stream_wait_ms(p, 109) == 1);
    assert(silly::stream_resume(p, key, silly::StreamEvent.Ready, 109, step) == silly::ResumeResult.Waiting);
    assert(silly::stream_resume(p, key, silly::StreamEvent.Ready, 110, step) == silly::ResumeResult.Applied);
    assert(silly::stream_resume(p, key, silly::StreamEvent.Input {
            bytes: "upload"
        }, 111, step)
        == silly::ResumeResult.Applied);
    assert(silly::stream_resume(p, key, silly::StreamEvent.InputEnd, 112, step) == silly::ResumeResult.Applied);
    assert(p.continuation.state.calls == 4);
    assert(p.continuation.state.inputs == 6);
    assert(p.continuation.state.ends == 1);
    assert(p.continuation.chunk[..3] == "abc");
    assert(p.continuation.produced == 3);
    assert(p.continuation.acknowledged == 1);
    assert(p.continuation.flush);
    assert(silly::stream_pending_bytes(p) == 2);
    assert(p.due_ms == 122);
    assert(silly::stream_acknowledge(p, key, 2) == silly::ResumeResult.Applied);
    assert(p.continuation.phase == silly::ContinuationPhase.Waiting);
    assert(silly::stream_wait_ms(p, 121) == 1);
    assert(silly::stream_cancel(p, key, step) == silly::ResumeResult.Applied);
    assert(p.continuation.state.cancelled == 1);
}

fn pending_failures(committed: bool, invalid: bool) {
    var p = producer();
    let key = p.continuation.key;
    assert(silly::stream_resume(p, key, silly::StreamEvent.Ready, 0, step) == silly::ResumeResult.Applied);
    if committed {
        silly::stream_commit(p, key);
    }
    p.continuation.state.invalid = invalid;
    let event: silly::StreamEvent = if invalid {
        silly::StreamEvent.Ready
    } else {
        silly::StreamEvent.InputFailed {
            reason: silly::StreamError.Input
        }
    };
    let result = silly::stream_resume(p, key, event, 10, step);
    let expected = if invalid {
        silly::ResumeResult.Invalid
    } else {
        silly::ResumeResult.Applied
    };
    assert(result == expected);
    assert(p.continuation.failure.selected == (!committed && !invalid));
    if p.continuation.failure.selected {
        assert(p.continuation.failure.status == 503);
        assert(p.continuation.failure.body == "mapped precommit");
    }
    assert(p.render_error == !committed);
    assert(p.close_required == committed);
    assert(silly::stream_pending_bytes(p) == 0);
    assert(p.continuation.state.cancelled == 1);
    assert(silly::stream_cancel(p, key, step) == silly::ResumeResult.Terminal);
    assert(p.continuation.state.cancelled == 1);
}

fn ordinary_and_timer_validation() {
    var p = producer(false);
    let key = p.continuation.key;
    assert(silly::stream_resume(p, key, silly::StreamEvent.Ready, 0, step) == silly::ResumeResult.Applied);
    assert(silly::stream_resume(p, key, silly::StreamEvent.InputEnd, 100, step) == silly::ResumeResult.Pending);
    assert(p.continuation.state.calls == 1);
    assert(silly::stream_wait_ms(p, 100) == 9223372036854775807);
    for delay in[-1, 9223372036854775807] {
        var broken = producer();
        broken.continuation.state.delay = delay;
        assert(silly::stream_resume(broken, key, silly::StreamEvent.Ready, 1, step)
            == silly::ResumeResult.Invalid);
        assert(broken.continuation.state.cancelled == 1);
        assert(broken.render_error);
    }
}

fn::main() {
    stream_duplex_test::pending_progress();
    stream_duplex_test::pending_failures(false, false);
    stream_duplex_test::pending_failures(true, false);
    stream_duplex_test::pending_failures(false, true);
    stream_duplex_test::pending_failures(true, true);
    stream_duplex_test::ordinary_and_timer_validation();
    print("duplex producer contracts passed");
}
