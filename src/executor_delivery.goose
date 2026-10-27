// Completion capacity is reserved by per-owner outstanding credits, including abandoned tasks.
namespace silly;

import std;

import.executor_response;
import.transport;
import.worker_message;

fn publish_lane_reply<Tag>(wake: i32, reply: LaneReply) {
    assert(qput(ExecReply<Tag> {
            key: reply.key,
            outcome: reply.outcome,
            head: reply.head,
            body: reply.body,
            completion: reply.completion,
            close_after_reply: reply.close_after_reply,
        }));
    silly_transport::notify(silly_transport::Descriptor {
            fd: wake
        });
}

fn deliver_lane_reply(start: LaneStart, reply: LaneReply) {
    let owner = reply.key.owner;
    assert(owner >= 0);
    assert(owner < 4);
    if owner == 0 {
        publish_lane_reply<IoOwner0>(start.owner_writers[0], reply);
    } else if owner == 1 {
        publish_lane_reply<IoOwner1>(start.owner_writers[1], reply);
    } else if owner == 2 {
        publish_lane_reply<IoOwner2>(start.owner_writers[2], reply);
    } else if owner == 3 {
        publish_lane_reply<IoOwner3>(start.owner_writers[3], reply);
    }
}
