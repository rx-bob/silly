// One owned chunk per producer. Duplex housekeeping never borrows pending output.
namespace silly;

import.continuation;
import.stream_contract;

struct StreamLimits {
    pending_bytes_max: i64 = CONTINUATION_CHUNK_BYTES,
}

struct StreamProducer<S> {
    continuation: Continuation<S>,
    limits: StreamLimits = StreamLimits {
        ..
    },
    committed: bool = false,
    duplex: bool = false,
    commit_requested: bool = false,
    render_error: bool = false,
    close_required: bool = false,
    due_ms: i64 = 0,
}

fn valid_stream_limits(limits: StreamLimits) -> bool {
    return limits.pending_bytes_max > 0 && limits.pending_bytes_max <= CONTINUATION_CHUNK_BYTES;
}

// Timer origin is the step that requested it, not the final transport acknowledgement.
// Duplex callbacks without downstream capacity receive a zero-length writer.
fn stream_resume<S, F>(producer: StreamProducer<S>&, key: TransferKey,
    event: StreamEvent, now: i64) -> ResumeResult {
    let slot .= producer.continuation;
    if !valid_transfer_key(key) || !key_equal(slot.key, key) {
        return ResumeResult.Stale;
    }
    if terminal(slot) {
        return ResumeResult.Terminal;
    }
    if event == StreamEvent.Cancelled {
        return stream_cancel(producer, key, F);
    }
    if slot.phase == ContinuationPhase.Pending && !producer.duplex {
        return ResumeResult.Pending;
    }
    if now < 0 || !valid_stream_limits(producer.limits) {
        stream_fail(producer, key, StreamError.InvalidStep, F);
        return ResumeResult.Invalid;
    }
    if !stream_event_ready(producer, event, now) {
        return ResumeResult.Waiting;
    }
    slot.chunk_capacity = producer.limits.pending_bytes_max;
    slot.failure_enabled = !producer.committed;
    let result = if slot.phase == ContinuationPhase.Pending {
        resume_pending(slot, event, F)
    } else {
        resume(slot, key, event, F)
    };
    if slot.phase == ContinuationPhase.Failed {
        stream_failure_policy(producer);
        return result;
    }
    if slot.phase == ContinuationPhase.Pending || slot.phase == ContinuationPhase.Completed {
        producer.commit_requested = true;
    }
    if !terminal(slot) && !stream_set_timer(producer, now) {
        stream_fail(producer, key, StreamError.InvalidStep, F);
        return ResumeResult.Invalid;
    }
    return result;
}

fn stream_event_ready<S>(producer: StreamProducer<S>&, event: StreamEvent, now: i64) -> bool {
    if producer.continuation.phase == ContinuationPhase.Ready {
        return event == StreamEvent.Ready;
    }
    match producer.continuation.wake {
        Ready => {
            return event == StreamEvent.Ready;
        },
        After _ => {
            return event == StreamEvent.Ready && now >= producer.due_ms;
        },
        InputAfter _ => {
            return (event == StreamEvent.Ready && now >= producer.due_ms) || input_event(event);
        },
        Input => {
            match event {
                Input _ => {
                    return true;
                },
                InputEnd => {
                    return true;
                },
                InputFailed _ => {
                    return true;
                },
                _ => {
                    return false;
                },
            }
        },
    }
}

fn stream_set_timer<S>(producer: StreamProducer<S>&, now: i64) -> bool {
    producer.due_ms = now;
    match producer.continuation.wake {
        After timer => {
            if timer.delay_ms > 9223372036854775807 - now {
                return false;
            }
            producer.due_ms = now + timer.delay_ms;
        },
        InputAfter timer => {
            if timer.delay_ms > 9223372036854775807 - now {
                return false;
            }
            producer.due_ms = now + timer.delay_ms;
        },
        _ => {
        },
    }
    return true;
}

fn stream_wait_ms<S>(producer: StreamProducer<S>&, now: i64) -> i64 {
    let slot .= producer.continuation;
    if terminal(slot) || (slot.phase == ContinuationPhase.Pending && !producer.duplex) {
        return 9223372036854775807;
    }
    if slot.phase == ContinuationPhase.Ready {
        return 0;
    }
    match slot.wake {
        Ready => {
            return 0;
        },
        After _ => {
            if now < 0 {
                return 0;
            }
            return if now >= producer.due_ms {
                0
            } else {
                producer.due_ms - now
            };
        },
        InputAfter _ => {
            return if now < 0 || now >= producer.due_ms {
                0
            } else {
                producer.due_ms - now
            };
        },
        Input => {
            return 9223372036854775807;
        },
    }
}

fn stream_pending_bytes<S>(producer: StreamProducer<S>&) -> i64 {
    if producer.continuation.phase != ContinuationPhase.Pending {
        return 0;
    }
    return producer.continuation.produced - producer.continuation.acknowledged;
}

fn stream_acknowledge<S>(producer: StreamProducer<S>&, key: TransferKey, count: i64) -> ResumeResult {
    return acknowledge(producer.continuation, key, count);
}

// Call immediately before offering the first response bytes to transport. Once committed,
// even a zero-byte/would-block write cannot authorize an alternate response.
fn stream_commit<S>(producer: StreamProducer<S>&, key: TransferKey) -> ResumeResult {
    let slot .= producer.continuation;
    if !valid_transfer_key(key) || !key_equal(slot.key, key) {
        return ResumeResult.Stale;
    }
    if slot.phase == ContinuationPhase.Failed || slot.phase == ContinuationPhase.Cancelled {
        return ResumeResult.Terminal;
    }
    producer.committed = true;
    producer.commit_requested = true;
    return ResumeResult.Applied;
}

fn stream_cancel<S, F>(producer: StreamProducer<S>&, key: TransferKey) -> ResumeResult {
    let result = cancel_continuation(producer.continuation, key, F);
    if result == ResumeResult.Applied {
        producer.close_required = true;
        producer.render_error = false;
        stream_discard_pending(producer);
    }
    return result;
}

fn stream_fail<S, F>(producer: StreamProducer<S>&, key: TransferKey, reason: StreamError) -> ResumeResult {
    let slot .= producer.continuation;
    if !valid_transfer_key(key) || !key_equal(slot.key, key) {
        return ResumeResult.Stale;
    }
    if terminal(slot) {
        return ResumeResult.Terminal;
    }
    slot.failure.selected = false;
    slot.phase = ContinuationPhase.Failed;
    slot.error = reason;
    slot.terminal_count += 1;
    notify_cancelled(slot, F);
    stream_failure_policy(producer);
    return ResumeResult.Applied;
}

fn stream_failure_policy<S>(producer: StreamProducer<S>&) {
    producer.render_error = !producer.committed;
    producer.close_required = producer.committed;
    stream_discard_pending(producer);
}

fn stream_discard_pending<S>(producer: StreamProducer<S>&) {
    producer.commit_requested = false;
    producer.continuation.produced = 0;
    producer.continuation.acknowledged = 0;
    producer.continuation.flush = false;
}

fn input_event(event: StreamEvent) -> bool {
    match event {
        Input _ => {
            return true;
        },
        InputEnd => {
            return true;
        },
        InputFailed _ => {
            return true;
        },
        _ => {
            return false;
        },
    }
}
