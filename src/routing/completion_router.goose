// Static owner mailboxes. Successful enqueue transfers one owned copy before wake notification.
namespace silly;

import std;

// Caller sets qlimit<WorkCompletion<Owner>> before producers start. Each mailbox has one live reader.
// expected_owner binds a static tag to the numeric owner selected by the startup dispatcher.
fn publish_completion<Owner>(expected_owner: i64, wake: silly_transport::Descriptor,
    completion: WorkCompletion<Owner>) -> PublishResult {
    if completion.key.owner != expected_owner {
        return PublishResult.WrongOwner;
    }
    if !qput(completion) {
        return PublishResult.Full;
    }
    let result = silly_transport::notify(wake);
    match result.status {
        Ready => {
            return PublishResult.Queued;
        },
        WouldBlock => {
            return PublishResult.Queued;
        },
        Interrupted => {
            return PublishResult.QueuedNeedsWake;
        },
        _ => {
            return PublishResult.QueuedOwnerGone;
        },
    }
}

// Retry only notification after QueuedNeedsWake: never enqueue the completion again.
// WouldBlock means an earlier wake is still readable. Drain wake bytes BEFORE the mailbox;
// never block after hitting the mailbox drain budget, because more completions may remain.
fn retry_completion_wake(wake: silly_transport::Descriptor) -> PublishResult {
    let result = silly_transport::notify(wake);
    match result.status {
        Ready => {
            return PublishResult.Queued;
        },
        WouldBlock => {
            return PublishResult.Queued;
        },
        Interrupted => {
            return PublishResult.QueuedNeedsWake;
        },
        _ => {
            return PublishResult.QueuedOwnerGone;
        },
    }
}

// Only after admission closes and every producer has joined may a supervisor replace the reader.
// The caller supplies the queue capacity, so discard work is finite even under shutdown errors.
fn discard_completions<Owner>(capacity: i64) -> i64 {
    var discarded = 0;
    for index in max(0, capacity) {
        let completion, present = qpoll<WorkCompletion<Owner>>();
        if !present {
            break;
        }
        discarded += 1;
    }
    return discarded;
}
