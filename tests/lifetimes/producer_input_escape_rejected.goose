// Expected rejection: producer state cannot retain a per-invocation input borrow.
namespace producer_input_escape_rejected;

import silly from "../..";

import std;

struct State {
    retained: const u8[:] = "",
}

fn step(state: State&, event: silly::StreamEvent, out: silly::ChunkWriter&) -> silly::StreamStep {
    match event {
        Input input => {
            state.retained = input.bytes;
        },
        _ => {
        },
    }
    return silly::StreamStep.Wait {
        wake: silly::Wake.Input,
    };
}

fn::main() {
    let key = silly::TransferKey {
        owner: 0,
        slot: 0,
        connection_generation: 1,
        request_generation: 1,
    };
    var producer = silly::StreamProducer<producer_input_escape_rejected::State> {
        continuation: silly::Continuation<producer_input_escape_rejected::State> {
            key: key,
            state: producer_input_escape_rejected::State {
            },
            ..
        },
        ..
    };
    silly::stream_resume(producer, key, silly::StreamEvent.Ready, 0, producer_input_escape_rejected::step);
    {
        var temporary: u8[3] = ['b', 'a', 'd'];
        silly::stream_resume(producer, key, silly::StreamEvent.Input {
                bytes: temporary,
            }, 1, producer_input_escape_rejected::step);
    }
    print(producer.continuation.state.retained);
}
