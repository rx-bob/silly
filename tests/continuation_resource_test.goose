// Terminal failure/cancellation closes an application-owned descriptor exactly once.
namespace continuation_resource_test;

import silly from "..";

import std;

struct ResourceState {
    socket: silly_transport::Descriptor,
    closes: i64 = 0,
}

fn release(state: ResourceState&) {
    assert(silly_transport::close(state.socket).status == silly_transport::IoStatus.Ready);
    state.closes += 1;
}

fn step(state: ResourceState&, event: silly::StreamEvent, out: silly::ChunkWriter&) -> silly::StreamStep {
    match event {
        Cancelled => {
            release(state);
            return silly::StreamStep.Done;
        },
        InputEnd => {
            release(state);
            return silly::StreamStep.Done;
        },
        InputFailed failure => {
            return silly::StreamStep.Failed {
                reason: failure.reason
            };
        },
        _ => {
            return silly::StreamStep.Wait {
                wake: silly::Wake.After {
                    delay_ms: -1
                }
            };
        },
    }
}

fn verify(event: silly::StreamEvent, phase: silly::ContinuationPhase) {
    var sockets = silly_transport::wake_pair();
    assert(sockets.status == silly_transport::IoStatus.Ready);
    let key = silly::TransferKey {
        owner: 0,
        slot: 0,
        connection_generation: 1,
        request_generation: 1
    };
    var transfer = silly::Continuation<ResourceState> {
        key: key,
        state: ResourceState {
            socket: sockets.reader,
            ..
        },
        ..
    };
    sockets.reader.fd = -1;
    silly::resume(transfer, key, event, step);
    assert(transfer.phase == phase);
    assert(transfer.state.socket.fd == -1);
    assert(transfer.state.closes == 1);
    assert(transfer.terminal_count == 1);
    assert(silly::cancel_continuation(transfer, key, step) == silly::ResumeResult.Terminal);
    assert(transfer.state.closes == 1);
    assert(silly_transport::notify(sockets.writer).status == silly_transport::IoStatus.Closed);
    assert(silly_transport::close(sockets.writer).status == silly_transport::IoStatus.Ready);
}

fn::main() {
    continuation_resource_test::verify(silly::StreamEvent.Ready, silly::ContinuationPhase.Failed);
    continuation_resource_test::verify(silly::StreamEvent.InputFailed {
            reason: silly::StreamError.Input
        }, silly::ContinuationPhase.Failed);
    continuation_resource_test::verify(silly::StreamEvent.Cancelled, silly::ContinuationPhase.Cancelled);
    continuation_resource_test::verify(silly::StreamEvent.InputEnd, silly::ContinuationPhase.Completed);
    print("continuation resource cleanup passed");
}
