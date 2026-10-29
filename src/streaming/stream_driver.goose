// Typed stream state stays in fixed slots owned by the listening execution owner.
namespace silly;

import.continuation;
import.stream;
import.stream_contract;

struct StreamSlot<S> {
    active: bool = false,
    deferred: bool = false,
    retained_limits: Limits = Limits {
    },
    retained_cap: i64 = 0,
    retained_fields: HeaderField[..128] = [],
    retained_headers: u8[..16384] = [],
    request_method: u8[..32] = [],
    fixed_remaining: i64 = -1,
    input_enabled: bool = false,
    input_ended: bool = false,
    input_failed: bool = false,
    input_eof: bool = false,
    input_started_ms: i64 = -1,
    input_stepped: bool = false,
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
