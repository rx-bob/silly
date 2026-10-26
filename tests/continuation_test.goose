// Owned state survives handler return; transport acknowledgements gate independent resumption.
namespace continuation_test;

import silly from "..";

import std;

struct State {
    label: u8[..16],
    calls: i64 = 0,
    cancellations: i64 = 0,
}

type Transfer = silly::Continuation<State>;

fn key(slot: i64, connection: u64 = 1, request: u64 = 1) -> silly::TransferKey {
    return silly::TransferKey {
        owner: 0,
        slot: slot,
        connection_generation: connection,
        request_generation: request
    };
}

fn handler(identity: silly::TransferKey, label: u8[:]) -> Transfer {
    var owned = State {
        label: [],
        ..
    };
    owned.label.append(label);
    return Transfer {
        key: identity,
        state: owned,
        ..
    };
}

fn step(state: State&, event: silly::StreamEvent, out: silly::ChunkWriter&) -> silly::StreamStep {
    match event {
        Cancelled => {
            state.cancellations += 1;
            assert(!silly::append(out, "forbidden"));
            return silly::StreamStep.Done;
        },
        Input chunk => {
            state.calls += 1;
            assert(silly::append(out, chunk.bytes));
            return silly::StreamStep.Chunk {
                flush: false,
                next: silly::Wake.Input
            };
        },
        InputEnd => {
            return silly::StreamStep.Done;
        },
        InputFailed error => {
            return silly::StreamStep.Failed {
                reason: error.reason
            };
        },
        Ready => {
        },
    }
    state.calls += 1;
    assert(silly::append(out, state.label));
    return silly::StreamStep.Chunk {
        flush: true,
        next: silly::Wake.After {
            delay_ms: 10
        }
    };
}

fn interleaved() {
    reusable var pool: Transfer[>..] = [];
    let first = pool.alloc_index(handler(key(0), "alpha"));
    let second = pool.alloc_index(handler(key(1), "beta"));
    assert(first == 0);
    assert(second == 1);
    assert(silly::resume(pool[first], key(first), silly::StreamEvent.Ready, step) == silly::ResumeResult.Applied);
    assert(silly::resume(pool[second], key(second), silly::StreamEvent.Ready, step) == silly::ResumeResult.Applied);
    assert(pool[first].chunk[..pool[first].produced] == "alpha");
    assert(pool[second].chunk[..pool[second].produced] == "beta");
    match pool[first].wake {
        After timer => {
            assert(timer.delay_ms == 10);
        },
        _ => {
            assert(false);
        },
    }
    assert(silly::acknowledge(pool[first], key(first), 2) == silly::ResumeResult.Applied);
    assert(silly::resume(pool[first], key(first), silly::StreamEvent.Ready, step) == silly::ResumeResult.Pending);
    assert(pool[first].state.calls == 1);
    assert(pool[first].acknowledged == 2);
    assert(silly::acknowledge(pool[second], key(second), 4) == silly::ResumeResult.Applied);
    assert(silly::resume(pool[second], key(second), silly::StreamEvent.Ready, step) == silly::ResumeResult.Applied);
    assert(pool[second].state.calls == 2);
    assert(pool[first].chunk[..5] == "alpha");
    assert(silly::acknowledge(pool[first], key(first), -1) == silly::ResumeResult.Invalid);
    assert(silly::acknowledge(pool[first], key(first), 4) == silly::ResumeResult.Invalid);
    assert(pool[first].acknowledged == 2);
    for index in 16 {
        pool.alloc_index(handler(key(index + 2), "growth"));
    }
    assert(pool[first].chunk[..5] == "alpha");
    assert(pool[second].chunk[..4] == "beta");
    assert(silly::acknowledge(pool[first], key(first), 3) == silly::ResumeResult.Applied);
    assert(silly::resume(pool[first], key(first), silly::StreamEvent.InputEnd, step) == silly::ResumeResult.Applied);
    assert(pool[first].terminal_count == 1);
    assert(silly::cancel_continuation(pool[first], key(first), step) == silly::ResumeResult.Terminal);
    assert(pool[first].state.cancellations == 0);
    assert(silly::cancel_continuation(pool[second], key(second), step) == silly::ResumeResult.Applied);
    assert(silly::cancel_continuation(pool[second], key(second), step) == silly::ResumeResult.Terminal);
    assert(pool[second].state.cancellations == 1);
    assert(pool[second].terminal_count == 1);
}

fn stale_completion() {
    reusable var pool: Transfer[>..] = [];
    let index = pool.alloc_index(handler(key(0), "old"));
    assert(silly::cancel_continuation(pool[index], key(index), step) == silly::ResumeResult.Applied);
    assert(silly::terminal(pool[index]));
    pool.free(index);
    let reused = pool.alloc_index(handler(key(0, 2), "new"));
    assert(reused == index);
    assert(pool[reused].produced == 0);
    assert(pool[reused].terminal_count == 0);
    assert(pool[reused].chunk[0] == 0);
    assert(silly::resume(pool[reused], key(reused, 2), silly::StreamEvent.Ready, step) == silly::ResumeResult.Applied);
    assert(silly::acknowledge(pool[reused], key(index), 3) == silly::ResumeResult.Stale);
    assert(silly::cancel_continuation(pool[reused], key(index), step) == silly::ResumeResult.Stale);
    assert(pool[reused].acknowledged == 0);
    assert(pool[reused].state.cancellations == 0);
    assert(silly::cancel_continuation(pool[reused], key(reused, 2), step) == silly::ResumeResult.Applied);
    pool.free(reused);
    let newer = pool.alloc_index(handler(key(0, 2, 2), "request two"));
    assert(newer == reused);
    assert(silly::resume(pool[newer], key(newer, 2, 2), silly::StreamEvent.Ready, step) == silly::ResumeResult.Applied);
    assert(silly::acknowledge(pool[newer], key(newer, 2, 1), 3) == silly::ResumeResult.Stale);
    assert(pool[newer].acknowledged == 0);
    var wrong_owner = key(newer, 2, 2);
    wrong_owner.owner = 1;
    assert(silly::acknowledge(pool[newer], wrong_owner, 3) == silly::ResumeResult.Stale);
    assert(pool[newer].chunk[..pool[newer].produced] == "request two");
    assert(silly::cancel_continuation(pool[newer], key(newer, 2, 2), step) == silly::ResumeResult.Applied);
}

fn input_and_failure() {
    var transfer = handler(key(0), "input");
    {
        var input: u8[>..] = [];
        input.append("borrowed");
        let event = silly::StreamEvent.Input {
            bytes: input
        };
        assert(silly::resume(transfer, key(0), event, step) == silly::ResumeResult.Applied);
    }
    assert(transfer.chunk[..transfer.produced] == "borrowed");
    assert(silly::acknowledge(transfer, key(0), 8) == silly::ResumeResult.Applied);
    let failure = silly::StreamEvent.InputFailed {
        reason: silly::StreamError.Input
    };
    assert(silly::resume(transfer, key(0), failure, step) == silly::ResumeResult.Applied);
    assert(transfer.phase == silly::ContinuationPhase.Failed);
    assert(transfer.error == silly::StreamError.Input);
    assert(transfer.state.cancellations == 1);
    assert(transfer.terminal_count == 1);
    assert(silly::resume(transfer, key(0), failure, step) == silly::ResumeResult.Terminal);
    assert(transfer.state.cancellations == 1);
    assert(transfer.terminal_count == 1);
}

fn invalid_step(state: State&, event: silly::StreamEvent, out: silly::ChunkWriter&) -> silly::StreamStep {
    if event == silly::StreamEvent.Cancelled {
        state.cancellations += 1;
        return silly::StreamStep.Done;
    }
    state.calls += 1;
    return silly::StreamStep.Wait {
        wake: silly::Wake.After {
            delay_ms: -1
        }
    };
}

fn invalid_outcome() {
    var transfer = handler(key(0), "bad");
    assert(silly::resume(transfer, key(0), silly::StreamEvent.Ready, invalid_step) == silly::ResumeResult.Invalid);
    assert(transfer.phase == silly::ContinuationPhase.Failed);
    assert(transfer.error == silly::StreamError.InvalidStep);
    assert(transfer.terminal_count == 1);
    assert(silly::resume(transfer, key(0), silly::StreamEvent.Ready, invalid_step) == silly::ResumeResult.Terminal);
    assert(transfer.state.calls == 1);
    assert(transfer.state.cancellations == 1);
}

fn wait_step(state: State&, event: silly::StreamEvent, out: silly::ChunkWriter&) -> silly::StreamStep {
    state.calls += 1;
    match event {
        Ready => {
            return silly::StreamStep.Wait {
                wake: silly::Wake.Input
            };
        },
        _ => {
            return silly::StreamStep.Done;
        },
    }
}

fn waiting_and_writer_bounds() {
    var transfer = handler(key(0), "waiting");
    assert(silly::resume(transfer, key(0), silly::StreamEvent.Ready, wait_step) == silly::ResumeResult.Applied);
    assert(transfer.phase == silly::ContinuationPhase.Waiting);
    assert(transfer.wake == silly::Wake.Input);
    assert(silly::acknowledge(transfer, key(0), 0) == silly::ResumeResult.Invalid);
    assert(silly::resume(transfer, key(0), silly::StreamEvent.InputEnd, wait_step) == silly::ResumeResult.Applied);
    assert(transfer.terminal_count == 1);
    var bytes: u8[3] = [0; 3];
    var writer = silly::ChunkWriter {
        bytes: bytes,
        ..
    };
    assert(silly::append(writer, "abc"));
    assert(!silly::append(writer, "d"));
    assert(writer.used == 3);
    assert(bytes == "abc");
}

fn::main() {
    continuation_test::interleaved();
    continuation_test::stale_completion();
    continuation_test::input_and_failure();
    continuation_test::invalid_outcome();
    continuation_test::waiting_and_writer_bounds();
    print("continuation contracts passed");
}
