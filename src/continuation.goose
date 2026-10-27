// Reusable-slot continuation state. No context, callback or input borrow survives a step.
namespace silly;

import.stream_contract;
import.stream_metadata_types;
import.transfer_key;

let CONTINUATION_CHUNK_BYTES = 4096;

enum ContinuationPhase {
    Ready,
    Pending,
    Waiting,
    Completed,
    Cancelled,
    Failed,
}

enum ResumeResult {
    Applied,
    Stale,
    Pending,
    Terminal,
    Invalid,
    Waiting,
}

struct Continuation<S> {
    key: TransferKey,
    state: S,
    phase: ContinuationPhase = ContinuationPhase.Ready,
    wake: Wake = Wake.Ready,
    error: StreamError = StreamError.InvalidStep,
    flush: bool = false,
    metadata: StreamMetadata = StreamMetadata {
    },
    failure: StreamFailureResponse = StreamFailureResponse {
    },
    failure_enabled: bool = true,
    chunk_capacity: i64 = CONTINUATION_CHUNK_BYTES,
    produced: i64 = 0,
    acknowledged: i64 = 0,
    terminal_count: i64 = 0,
    chunk: u8[CONTINUATION_CHUNK_BYTES] = [0; CONTINUATION_CHUNK_BYTES],
}

fn terminal<S>(slot: Continuation<S>&) -> bool {
    return slot.phase == ContinuationPhase.Completed || slot.phase == ContinuationPhase.Cancelled
        || slot.phase == ContinuationPhase.Failed;
}

// Ready/event readiness is checked by the owner before calling; Pending always forbids reuse.
fn resume<S, F>(slot: Continuation<S>&, key: TransferKey, event: StreamEvent) -> ResumeResult {
    if !valid_transfer_key(key) || !key_equal(slot.key, key) {
        return ResumeResult.Stale;
    }
    if terminal(slot) {
        return ResumeResult.Terminal;
    }
    match event {
        Cancelled => {
            return cancel_continuation(slot, key, F);
        },
        _ => {
        },
    }
    if slot.phase == ContinuationPhase.Pending {
        return ResumeResult.Pending;
    }
    if slot.chunk_capacity <= 0 || slot.chunk_capacity > CONTINUATION_CHUNK_BYTES {
        let result = fail_continuation(slot);
        notify_cancelled(slot, F);
        return result;
    }
    slot.failure.selected = false;
    var writer = ChunkWriter {
        bytes: slot.chunk[..slot.chunk_capacity],
        metadata: slot.metadata,
        failure: if slot.failure_enabled {
            slot.failure
        } else {
            null
        },
        ..
    };
    let step = F(slot.state, event, writer);
    let result = apply_step(slot, step, writer.used);
    if slot.phase != ContinuationPhase.Failed {
        slot.failure.selected = false;
    }
    if slot.phase == ContinuationPhase.Failed {
        notify_cancelled(slot, F);
    }
    return result;
}

// Duplex housekeeping cannot overwrite a chunk still owned by the transport.
fn resume_pending<S, F>(slot: Continuation<S>&, event: StreamEvent) -> ResumeResult {
    var bytes: u8[0] = [];
    slot.failure.selected = false;
    var writer = ChunkWriter {
        bytes: bytes,
        failure: if slot.failure_enabled {
            slot.failure
        } else {
            null
        },
        ..
    };
    let step = F(slot.state, event, writer);
    match step {
        Wait wait => {
            if writer.used == 0 && valid_wake(wait.wake) {
                slot.failure.selected = false;
                slot.wake = wait.wake;
                return ResumeResult.Applied;
            }
        },
        Failed failure => {
            slot.error = failure.reason;
            slot.phase = ContinuationPhase.Failed;
            slot.terminal_count += 1;
            notify_cancelled(slot, F);
            return ResumeResult.Applied;
        },
        _ => {
        },
    }
    let result = fail_continuation(slot);
    notify_cancelled(slot, F);
    return result;
}

fn apply_step<S>(slot: Continuation<S>&, step: StreamStep, produced: i64) -> ResumeResult {
    match step {
        Chunk chunk => {
            if produced <= 0 || produced > slot.chunk_capacity || !valid_wake(chunk.next) {
                return fail_continuation(slot);
            }
            slot.produced = produced;
            slot.acknowledged = 0;
            slot.flush = chunk.flush;
            slot.wake = chunk.next;
            slot.phase = ContinuationPhase.Pending;
        },
        Wait wait => {
            if produced != 0 || !valid_wake(wait.wake) {
                return fail_continuation(slot);
            }
            slot.wake = wait.wake;
            slot.phase = ContinuationPhase.Waiting;
        },
        Done => {
            if produced != 0 {
                return fail_continuation(slot);
            }
            slot.phase = ContinuationPhase.Completed;
            slot.terminal_count += 1;
        },
        Failed failure => {
            slot.error = failure.reason;
            slot.phase = ContinuationPhase.Failed;
            slot.terminal_count += 1;
        },
    }
    return ResumeResult.Applied;
}

// Transport returns counts, never addresses. Stale, negative and overlarge acknowledgements are inert.
fn acknowledge<S>(slot: Continuation<S>&, key: TransferKey, count: i64) -> ResumeResult {
    if !valid_transfer_key(key) || !key_equal(slot.key, key) {
        return ResumeResult.Stale;
    }
    if terminal(slot) {
        return ResumeResult.Terminal;
    }
    if slot.phase != ContinuationPhase.Pending || count < 0 || count > slot.produced - slot.acknowledged {
        return ResumeResult.Invalid;
    }
    slot.acknowledged += count;
    if slot.acknowledged == slot.produced {
        slot.phase = ContinuationPhase.Waiting;
    }
    return ResumeResult.Applied;
}

fn cancel_continuation<S, F>(slot: Continuation<S>&, key: TransferKey) -> ResumeResult {
    if !valid_transfer_key(key) || !key_equal(slot.key, key) {
        return ResumeResult.Stale;
    }
    if terminal(slot) {
        return ResumeResult.Terminal;
    }
    // Mark terminal before application cleanup. A cancellation callback cannot re-open this transfer.
    slot.phase = ContinuationPhase.Cancelled;
    slot.error = StreamError.Cancelled;
    slot.terminal_count += 1;
    notify_cancelled(slot, F);
    return ResumeResult.Applied;
}

// Failure and explicit cancellation share one cleanup callback; its output/outcome is ignored.
fn notify_cancelled<S, F>(slot: Continuation<S>&) {
    var bytes: u8[0] = [];
    var writer = ChunkWriter {
        bytes: bytes,
        ..
    };
    F(slot.state, StreamEvent.Cancelled, writer);
}

fn fail_continuation<S>(slot: Continuation<S>&) -> ResumeResult {
    slot.failure.selected = false;
    slot.error = StreamError.InvalidStep;
    slot.phase = ContinuationPhase.Failed;
    slot.terminal_count += 1;
    return ResumeResult.Invalid;
}
