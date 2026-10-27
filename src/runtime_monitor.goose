// A monitor has no application callbacks: it waits for one contained owner then reports its exit.
namespace silly;

import std;

import.shutdown_types;
import.transport;

thread_fn monitor_runtime_thread(thread: i64, lane: bool, index: i64, wake: i32) {
    let ok = thread_wait(thread);
    assert(qput(RuntimeExit {
            thread: thread,
            lane: lane,
            index: index,
            ok: ok
        }));
    silly_transport::notify(silly_transport::Descriptor {
            fd: wake
        });
}

fn start_runtime_monitor(owner: RuntimeWorker&, lane: bool, index: i64, wake: i32) {
    owner.monitor = thread_spawn(monitor_runtime_thread, owner.thread, lane, index, wake);
}

fn record_runtime_exit(event: RuntimeExit, workers: RuntimeWorker[:], lanes: RuntimeWorker[:]) -> bool {
    if event.lane {
        return record_owner_exit(event, lanes);
    }
    return record_owner_exit(event, workers);
}

fn record_owner_exit(event: RuntimeExit, owners: RuntimeWorker[:]) -> bool {
    if event.index < 0 || event.index >= owners.len || owners[event.index].thread != event.thread {
        return false;
    }
    owners[event.index].exited = true;
    owners[event.index].aborted = !event.ok;
    return true;
}

fn runtime_owners_exited(owners: RuntimeWorker[:]) -> bool {
    for owner in owners {
        if !owner.exited {
            return false;
        }
    }
    return true;
}

fn join_runtime_monitors(owners: RuntimeWorker[:]) {
    for owner in owners {
        // Exit was published after the application owner joined. Only a nonblocking wake remains here.
        assert(owner.exited);
        assert(thread_wait(owner.monitor));
    }
}
