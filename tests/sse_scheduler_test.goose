// Heartbeats use the ordinary bounded producer clock; pending output suppresses event accumulation.
namespace sse_scheduler_test;

import silly from "..";

import std;

struct State {
    calls: i64 = 0,
    cleanup: i64 = 0,
}
type Producer = silly::StreamProducer<State>;

fn key() -> silly::TransferKey {
    return silly::TransferKey {
        owner: 0,
        slot: 0,
        connection_generation: 1,
        request_generation: 1
    };
}

fn producer() -> Producer {
    return Producer {
        continuation: silly::Continuation<State> {
            key: key(),
            state: State {
            },
            ..
        },
        limits: silly::StreamLimits {
            pending_bytes_max: 64
        },
        ..
    };
}

fn step(state: State&, event: silly::StreamEvent, out: silly::ChunkWriter&) -> silly::StreamStep {
    if event == silly::StreamEvent.Cancelled {
        state.cleanup += 1;
        assert(out.bytes.len == 0);
        return silly::StreamStep.Done;
    }
    assert(event == silly::StreamEvent.Ready);
    state.calls += 1;
    if state.calls == 4 {
        state.cleanup += 1;
        return silly::StreamStep.Done;
    }
    let ok = if state.calls == 2 {
        silly::sse_comment(out, "heartbeat")
    } else {
        silly::sse_event(out, silly::SseEvent {
                data: "tick",
                ..
            })
    };
    assert(ok);
    return silly::StreamStep.Chunk {
        flush: true,
        next: silly::Wake.After {
            delay_ms: 10
        }
    };
}

fn drain(producer: Producer&) {
    let size = silly::stream_pending_bytes(producer);
    assert(size > 0);
    for index in size {
        assert(silly::stream_acknowledge(producer, key(), 1) == silly::ResumeResult.Applied);
    }
}

fn heartbeat_and_cancel() {
    var source = producer();
    assert(silly::stream_resume(source, key(), silly::StreamEvent.Ready, 100, step) == silly::ResumeResult.Applied);
    assert(source.continuation.chunk[..source.continuation.produced] == "data: tick\n\n");
    assert(source.continuation.flush);
    assert(silly::stream_commit(source, key()) == silly::ResumeResult.Applied);
    assert(silly::stream_acknowledge(source, key(), 0) == silly::ResumeResult.Applied);
    assert(silly::stream_acknowledge(source, key(), 2) == silly::ResumeResult.Applied);
    for turn in 100 {
        assert(silly::stream_resume(source, key(), silly::StreamEvent.Ready, 200 + turn, step)
            == silly::ResumeResult.Pending);
    }
    assert(source.continuation.state.calls == 1);
    assert(source.due_ms == 110);
    assert(silly::stream_acknowledge(source, key(), source.continuation.produced - 2)
        == silly::ResumeResult.Applied);
    assert(silly::stream_resume(source, key(), silly::StreamEvent.Ready, 300, step) == silly::ResumeResult.Applied);
    assert(source.continuation.chunk[..source.continuation.produced] == ": heartbeat\n\n");
    assert(source.due_ms == 310);
    drain(source);
    assert(silly::stream_resume(source, key(), silly::StreamEvent.Ready, 309, step) == silly::ResumeResult.Waiting);
    assert(source.continuation.state.calls == 2);
    assert(silly::stream_cancel(source, key(), step) == silly::ResumeResult.Applied);
    assert(silly::stream_cancel(source, key(), step) == silly::ResumeResult.Terminal);
    assert(silly::stream_resume(source, key(), silly::StreamEvent.Ready, 10000, step) == silly::ResumeResult.Terminal);
    assert(source.continuation.state.calls == 2);
    assert(source.continuation.state.cleanup == 1);
    assert(silly::stream_pending_bytes(source) == 0);
}

fn finite_source() {
    var source = producer();
    for index in 3 {
        assert(silly::stream_resume(source, key(), silly::StreamEvent.Ready, index * 10, step)
            == silly::ResumeResult.Applied);
        drain(source);
    }
    assert(silly::stream_resume(source, key(), silly::StreamEvent.Ready, 30, step) == silly::ResumeResult.Applied);
    assert(source.continuation.phase == silly::ContinuationPhase.Completed);
    assert(source.continuation.state.cleanup == 1);
    assert(silly::stream_cancel(source, key(), step) == silly::ResumeResult.Terminal);
    assert(source.continuation.state.cleanup == 1);
}

fn::main() {
    sse_scheduler_test::heartbeat_and_cancel();
    sse_scheduler_test::finite_source();
    print("SSE heartbeat timing, bounded backpressure and cancellation passed");
}
