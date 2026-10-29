// Finite static owner table; only the supervisor publishes accepted descriptors.
namespace silly;

import std;

import.work_message;
import.worker_message;

fn initialize_worker_mailbox<Tag>(capacity: i64) {
    qlimit<AcceptMessage<Tag>>(capacity);
    qlimit<WorkerStop<Tag>>(1);
}

fn initialize_runtime_mailboxes(capacity: i64) {
    initialize_worker_mailbox<IoOwner0>(capacity);
    initialize_worker_mailbox<IoOwner1>(capacity);
    initialize_worker_mailbox<IoOwner2>(capacity);
    initialize_worker_mailbox<IoOwner3>(capacity);
    qlimit<WorkerReport>(8);
}

fn route_accept(owner: i64, wake: silly_transport::Descriptor,
    socket: silly_transport::Descriptor&, listener_id: i64 = 0) -> PublishResult {
    if owner == 0 {
        return publish_accept<IoOwner0>(wake, socket, listener_id);
    }
    if owner == 1 {
        return publish_accept<IoOwner1>(wake, socket, listener_id);
    }
    if owner == 2 {
        return publish_accept<IoOwner2>(wake, socket, listener_id);
    }
    return publish_accept<IoOwner3>(wake, socket, listener_id);
}

fn stop_worker<Tag>(wake: silly_transport::Descriptor) {
    // Refusal means a stop is already pending; no retry or extra control message is required.
    if !qput(WorkerStop<Tag> {
        }) {
        return;
    }
    // One bounded notification. Timed polls also check the stop mailbox, even after EINTR.
    silly_transport::notify(wake);
}

fn route_worker_stop(owner: i64, wake: silly_transport::Descriptor) {
    if owner == 0 {
        stop_worker<IoOwner0>(wake);
    } else if owner == 1 {
        stop_worker<IoOwner1>(wake);
    } else if owner == 2 {
        stop_worker<IoOwner2>(wake);
    } else {
        stop_worker<IoOwner3>(wake);
    }
}

fn reclaim_worker<Tag>(capacity: i64) {
    discard_accepts<Tag>(capacity);
    let stop, present = qpoll<WorkerStop<Tag>>();
}

fn reclaim_runtime_mailboxes(capacity: i64) {
    reclaim_worker<IoOwner0>(capacity);
    reclaim_worker<IoOwner1>(capacity);
    reclaim_worker<IoOwner2>(capacity);
    reclaim_worker<IoOwner3>(capacity);
}
