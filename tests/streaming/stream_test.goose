// Production producer ownership, bounded backpressure and wake/commit policy.
namespace stream_test;

import silly from "../../";

import std;

struct State {
    label: u8[..8] = [],
    calls: i64 = 0,
    cancelled: i64 = 0,
    completed: i64 = 0,
    delay: i64 = 10,
}

type Producer = silly::StreamProducer<State>;

fn key(generation: u64 = 1) -> silly::TransferKey {
    return silly::TransferKey {
        owner: 0,
        slot: 0,
        connection_generation: generation,
        request_generation: 1,
    };
}

fn handler(label: u8[:], generation: u64 = 1) -> Producer {
    var state = State {
    };
    state.label.append(label);
    return Producer {
        continuation: silly::Continuation<State> {
            key: key(generation),
            state: state,
            ..
        },
        limits: silly::StreamLimits {
            pending_bytes_max: 3,
        },
        ..
    };
}

fn step(state: State&, event: silly::StreamEvent, out: silly::ChunkWriter&) -> silly::StreamStep {
    match event {
        Cancelled => {
            state.cancelled += 1;
            assert(out.bytes.len == 0);
            assert(!silly::append(out, "x"));
            return silly::StreamStep.Done;
        },
        InputFailed failure => {
            state.calls += 1;
            return silly::StreamStep.Failed {
                reason: failure.reason,
            };
        },
        InputEnd => {
            state.calls += 1;
            state.completed += 1;
            return silly::StreamStep.Done;
        },
        Input input => {
            state.calls += 1;
            assert(silly::append(out, input.bytes));
            return silly::StreamStep.Chunk {
                flush: false,
                next: silly::Wake.Input,
            };
        },
        Ready => {
        },
    }
    state.calls += 1;
    assert(silly::append(out, state.label));
    assert(!silly::append(out, "overflow"));
    return silly::StreamStep.Chunk {
        flush: true,
        next: silly::Wake.After {
            delay_ms: state.delay,
        },
    };
}

fn backpressure() {
    var first = handler("abc");
    var second = handler("xyz");
    assert(silly::stream_resume(first, key(), silly::StreamEvent.InputEnd, 100, step)
        == silly::ResumeResult.Waiting);
    assert(first.continuation.state.calls == 0);
    assert(silly::stream_resume(first, key(), silly::StreamEvent.Ready, 100, step)
        == silly::ResumeResult.Applied);
    assert(first.continuation.chunk[..3] == "abc");
    assert(first.commit_requested);
    assert(!first.committed);
    assert(first.due_ms == 110);
    assert(silly::stream_pending_bytes(first) == 3);
    assert(silly::stream_acknowledge(first, key(), 0) == silly::ResumeResult.Applied);
    assert(silly::stream_pending_bytes(first) == 3);
    assert(silly::stream_resume(first, key(), silly::StreamEvent.Ready, 200, step)
        == silly::ResumeResult.Pending);
    assert(first.continuation.state.calls == 1);
    assert(silly::stream_resume(second, key(), silly::StreamEvent.Ready, 100, step)
        == silly::ResumeResult.Applied);
    var delivered: u8[>..] = [];
    for index in 3 {
        delivered.append(first.continuation.chunk[index..index + 1]);
        assert(silly::stream_acknowledge(first, key(), 1) == silly::ResumeResult.Applied);
        assert(first.continuation.state.calls == 1);
        assert(first.continuation.chunk[..3] == "abc");
    }
    assert(delivered == "abc");
    assert(silly::stream_pending_bytes(first) == 0);
    assert(silly::stream_pending_bytes(second) == 3);
    assert(first.due_ms == 110);
    assert(silly::stream_wait_ms(first, 109) == 1);
    assert(silly::stream_resume(first, key(), silly::StreamEvent.Ready, 109, step)
        == silly::ResumeResult.Waiting);
    assert(silly::stream_resume(first, key(), silly::StreamEvent.Ready, 110, step)
        == silly::ResumeResult.Applied);
    assert(first.continuation.state.calls == 2);
    assert(silly::stream_cancel(first, key(), step) == silly::ResumeResult.Applied);
    assert(silly::stream_cancel(second, key(), step) == silly::ResumeResult.Applied);
}

fn input_step(state: State&, event: silly::StreamEvent, out: silly::ChunkWriter&) -> silly::StreamStep {
    if event == silly::StreamEvent.Ready {
        state.calls += 1;
        return silly::StreamStep.Wait {
            wake: silly::Wake.Input,
        };
    }
    return step(state, event, out);
}

fn input_and_end() {
    var producer = handler("abc");
    assert(silly::stream_resume(producer, key(), silly::StreamEvent.Ready, 0, input_step)
        == silly::ResumeResult.Applied);
    assert(!producer.commit_requested);
    assert(silly::stream_wait_ms(producer, 10) == 9223372036854775807);
    assert(silly::stream_resume(producer, key(), silly::StreamEvent.Ready, 10, input_step)
        == silly::ResumeResult.Waiting);
    {
        var bytes: u8[3] = ['i', 'n', '!'];
        assert(silly::stream_resume(producer, key(), silly::StreamEvent.Input {
                bytes: bytes,
            }, 10, input_step) == silly::ResumeResult.Applied);
        bytes[0] = 'x';
    }
    assert(producer.continuation.chunk[..3] == "in!");
    assert(silly::stream_acknowledge(producer, key(), -1) == silly::ResumeResult.Invalid);
    assert(silly::stream_acknowledge(producer, key(), 4) == silly::ResumeResult.Invalid);
    assert(silly::stream_acknowledge(producer, key(), 3) == silly::ResumeResult.Applied);
    assert(silly::stream_resume(producer, key(), silly::StreamEvent.InputEnd, 11, input_step)
        == silly::ResumeResult.Applied);
    assert(producer.continuation.phase == silly::ContinuationPhase.Completed);
    assert(producer.continuation.state.completed == 1);
    assert(silly::stream_cancel(producer, key(), input_step) == silly::ResumeResult.Terminal);
    assert(producer.continuation.state.cancelled == 0);
    assert(producer.continuation.terminal_count == 1);
}

fn failure_policy(committed: bool) {
    var producer = handler("abc");
    assert(silly::stream_resume(producer, key(), silly::StreamEvent.Ready, 0, step)
        == silly::ResumeResult.Applied);
    if committed {
        assert(silly::stream_commit(producer, key()) == silly::ResumeResult.Applied);
    }
    assert(silly::stream_fail(producer, key(), silly::StreamError.Transport, step)
        == silly::ResumeResult.Applied);
    assert(producer.render_error == !committed);
    assert(producer.close_required == committed);
    assert(!producer.commit_requested);
    assert(silly::stream_pending_bytes(producer) == 0);
    assert(producer.continuation.produced == 0);
    assert(producer.continuation.state.cancelled == 1);
    assert(producer.continuation.terminal_count == 1);
    assert(silly::stream_acknowledge(producer, key(), 3) == silly::ResumeResult.Terminal);
    assert(silly::stream_fail(producer, key(), silly::StreamError.Input, step)
        == silly::ResumeResult.Terminal);
    assert(silly::stream_cancel(producer, key(), step) == silly::ResumeResult.Terminal);
    assert(producer.continuation.state.cancelled == 1);
}

fn returned_failure() {
    var producer = handler("abc");
    assert(silly::stream_resume(producer, key(), silly::StreamEvent.Ready, 0, input_step)
        == silly::ResumeResult.Applied);
    assert(silly::stream_resume(producer, key(), silly::StreamEvent.InputFailed {
            reason: silly::StreamError.Input,
        }, 1, input_step) == silly::ResumeResult.Applied);
    assert(producer.continuation.error == silly::StreamError.Input);
    assert(producer.continuation.phase == silly::ContinuationPhase.Failed);
    assert(producer.continuation.state.cancelled == 1);
    assert(producer.render_error);
    assert(!producer.close_required);
    assert(silly::stream_cancel(producer, key(), input_step) == silly::ResumeResult.Terminal);
    assert(producer.continuation.state.cancelled == 1);
}

fn invalid_step(state: State&, event: silly::StreamEvent, out: silly::ChunkWriter&) -> silly::StreamStep {
    if event == silly::StreamEvent.Cancelled {
        return step(state, event, out);
    }
    state.calls += 1;
    out.used = out.bytes.len + 1;
    return silly::StreamStep.Chunk {
        flush: true,
        next: silly::Wake.Ready,
    };
}

fn invalid_and_overflow() {
    var invalid = handler("abc");
    assert(silly::stream_resume(invalid, key(), silly::StreamEvent.Ready, 0, invalid_step)
        == silly::ResumeResult.Invalid);
    assert(invalid.continuation.error == silly::StreamError.InvalidStep);
    assert(invalid.continuation.state.cancelled == 1);
    assert(invalid.render_error);
    var overflow = handler("abc");
    overflow.continuation.state.delay = 9223372036854775807;
    assert(silly::stream_resume(overflow, key(), silly::StreamEvent.Ready, 1, step)
        == silly::ResumeResult.Invalid);
    assert(overflow.continuation.state.cancelled == 1);
    assert(overflow.render_error);
    assert(silly::stream_pending_bytes(overflow) == 0);
    var limits = handler("abc");
    limits.limits.pending_bytes_max = 0;
    assert(silly::stream_resume(limits, key(), silly::StreamEvent.Ready, 0, step)
        == silly::ResumeResult.Invalid);
    assert(limits.continuation.state.calls == 0);
    assert(limits.continuation.state.cancelled == 1);
    assert(!silly::valid_stream_limits(silly::StreamLimits {
            pending_bytes_max: silly::CONTINUATION_CHUNK_BYTES + 1,
        }));
}

fn reused_slot() {
    var producer = handler("old");
    assert(silly::stream_resume(producer, key(), silly::StreamEvent.Ready, 0, step)
        == silly::ResumeResult.Applied);
    assert(silly::stream_cancel(producer, key(), step) == silly::ResumeResult.Applied);
    assert(producer.continuation.state.cancelled == 1);
    assert(producer.close_required);
    assert(silly::stream_pending_bytes(producer) == 0);
    producer = handler("new", 2);
    assert(silly::stream_resume(producer, key(), silly::StreamEvent.Ready, 0, step)
        == silly::ResumeResult.Stale);
    assert(silly::stream_commit(producer, key()) == silly::ResumeResult.Stale);
    assert(silly::stream_acknowledge(producer, key(), 1) == silly::ResumeResult.Stale);
    assert(silly::stream_cancel(producer, key(), step) == silly::ResumeResult.Stale);
    assert(producer.continuation.state.calls == 0);
    assert(producer.continuation.state.cancelled == 0);
    assert(silly::stream_resume(producer, key(2), silly::StreamEvent.Ready, 0, step)
        == silly::ResumeResult.Applied);
    assert(producer.continuation.chunk[..3] == "new");
    assert(silly::stream_cancel(producer, key(2), step) == silly::ResumeResult.Applied);
    assert(producer.continuation.state.cancelled == 1);
}

fn::main() {
    stream_test::backpressure();
    stream_test::input_and_end();
    stream_test::failure_policy(false);
    stream_test::failure_policy(true);
    stream_test::returned_failure();
    stream_test::invalid_and_overflow();
    stream_test::reused_slot();
    print("stream producer contracts passed");
}
