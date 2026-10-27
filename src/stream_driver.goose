// Typed stream state stays in fixed slots owned by the listening execution owner.
namespace silly;

import.connection;
import.context;
import.continuation;
import.execution_types;
import.headers;
import.http_head_types;
import.lifecycle_driver;
import.response_policy;
import.response_policy_types;
import.response_wire_types;
import.server_body;
import.server_executor;
import.stream;
import.stream_contract;
import.transfer_key;
import.wire_transfer;

struct StreamSlot<S> {
    active: bool = false,
    start: StreamStart<S> = StreamStart<S> {
    },
    producer: StreamProducer<S> = StreamProducer<S> {
        continuation: Continuation<S> {
            key: TransferKey {
                owner: 0,
                slot: 0,
                connection_generation: 1,
                request_generation: 1
            },
            state: default<S>(),
            ..
        },
        ..
    },
    framing: ResponseFraming = ResponseFraming.None,
    cursor: WireCursor = WireCursor {
    },
    prefix: u8[..18] = [],
    chunk_started: bool = false,
    ending: bool = false,
}

struct StreamDriver<R, A, S> {
    lifecycle: LifecycleDriver<R,
    A>,
    slots: StreamSlot<S>[:],
    current: i64 = 0,
}

fn body_admission<R, A, S>(driver: StreamDriver<R, A, S> & , parsed: ParsedHead, cap: i64) -> BodyAdmission {
    return body_admission(driver.lifecycle.plan, parsed, cap);
}

fn resolve_response_policy<R, A, S>(driver: StreamDriver<R, A, S> & , parsed: ParsedHead,
    fields: HeaderView[:]) -> ResponsePolicyState {
    return resolve_response_policy(driver.lifecycle, parsed, fields);
}

fn queue_execution<R, A, S>(driver: StreamDriver<R, A, S> & , connection: Connection&,
    buffers: ConnectionBuffers) -> ExecutionOutcome {
    return ExecutionOutcome.Unavailable;
}

fn driver_control_epoch<R, A, S>(driver: StreamDriver<R, A, S> & ) -> i64 {
    return 0;
}

fn permit_inline<R, A, S>(driver: StreamDriver<R, A, S> & ) -> bool {
    return true;
}
