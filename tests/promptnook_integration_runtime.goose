// Two listener identities share exactly one native-state owner and two independent I/O owners.
namespace pn_integration;

import silly from "..";

import std;

import.body_socket_fixture;
import.native_control;
import.native_socket_fixture;
import.promptnook_integration_handlers;
import.promptnook_integration_types;

fn options() -> silly::RuntimeOptions {
    return silly::RuntimeOptions {
        workers: 2,
        accept_queue_max: 4,
        connections_max: 32,
        worker: silly::WorkerOptions {
            limits: silly::Limits {
                head_bytes_max: 4096,
                body_bytes_max: 262144,
                output_bytes_max: 2048,
                ..
            },
            connections_max: 4,
            response_head_bytes_max: 2048,
            accepts_per_turn: 4,
            work_bytes_per_turn: 4096,
            poll_timeout_ms: 5,
            ..
        },
        executor: silly::ExecutorOptions {
            serialized_name: "promptnook_native",
            lanes: 1,
            queue_max: 4,
            outstanding_per_owner: 4,
            body_bytes_max: 65536,
            response_body_bytes_max: 2048,
            task_timeout_ms: 10000,
            ..
        },
        ..
    };
}
thread_fn io_worker(start: silly::WorkerStart, seed: i64) {
    silly::run_runtime_worker<Route>(start, seed, initialize, define, handle, lifecycle);
}
thread_fn lane_worker(start: silly::LaneStart, seed: i64) {
    silly::run_executor_lane<Route>(start, seed, initialize, define, handle, lifecycle);
}
thread_fn supervisor(api: i32, portal: i32, wake: i32) {
    var listeners: silly_transport::Descriptor[2] = [silly_transport::Descriptor {
            fd: api
        },
        silly_transport::Descriptor {
            fd: portal
        }];
    let result = silly::run_runtime_listeners_with_executor(options(), listeners,
        silly_transport::Descriptor {
            fd: wake
        }, 0, io_worker, lane_worker);
    assert(qput(Returned {
            ok: result.ok,
            drain: result.drain,
            pending: result.pending.active
        }));
}

fn start() -> Running {
    assert(native_control::native_test_reset(0) == 0);
    qlimit<Started>(3);
    qlimit<Stopped>(3);
    qlimit<Finished>(128);
    qlimit<Returned>(1);
    var api = silly_transport::listen("127.0.0.1", 0, 8);
    var portal = silly_transport::listen("127.0.0.1", 0, 8);
    assert(api.status == silly_transport::IoStatus.Ready);
    assert(portal.status == silly_transport::IoStatus.Ready);
    let api_port = silly_transport::local_port(api.descriptor).count as i32;
    let portal_port = silly_transport::local_port(portal.descriptor).count as i32;
    var wake = silly_transport::wake_pair();
    assert(wake.status == silly_transport::IoStatus.Ready);
    let owner = thread_spawn(supervisor, api.descriptor.fd, portal.descriptor.fd, wake.reader.fd);
    api.descriptor.fd = -1;
    portal.descriptor.fd = -1;
    wake.reader.fd = -1;
    var native: i64 = 0;
    var seen: bool[3] = [false; 3];
    for index in 3 {
        let started, present = qget<Started>(10000);
        assert(present);
        let slot = if started.owner.lane < 0 {
            started.owner.id
        } else {
            2
        };
        assert(slot >= 0);
        assert(slot < 3);
        assert(!seen[slot]);
        seen[slot] = true;
        if started.owner.is_serialized("promptnook_native") {
            native += 1;
        }
    }
    assert(native == 1);
    assert(native_control::native_test_metric(0) == 1);
    return Running {
        thread: owner,
        api: api_port,
        portal: portal_port,
        wake: wake.writer
    };
}

fn finish(running: Running&) {
    assert(silly_transport::notify(running.wake).status == silly_transport::IoStatus.Ready);
    let returned, done = qget<Returned>(10000);
    assert(done);
    assert(returned.ok);
    assert(returned.drain == silly::DrainStatus.Complete);
    assert(!returned.pending);
    assert(thread_wait(running.thread));
    var native: i64 = 0;
    var seen: bool[3] = [false; 3];
    for index in 3 {
        let stopped, present = qpoll<Stopped>();
        assert(present);
        let slot = if stopped.owner.lane < 0 {
            stopped.owner.id
        } else {
            2
        };
        assert(slot >= 0);
        assert(slot < 3);
        assert(!seen[slot]);
        seen[slot] = true;
        assert(!stopped.opened);
        if stopped.owner.is_serialized("promptnook_native") {
            native += 1;
        }
    }
    assert(native == 1);
    assert(native_control::native_test_metric(1) == 1);
    assert(native_control::native_test_metric(2) == 0);
    let extra, present = qpoll<Stopped>();
    assert(!present);
    closed_listener(running.api);
    closed_listener(running.portal);
    silly_transport::close(running.wake);
}

fn closed_listener(port: i32) {
    var socket = silly_transport::connect("127.0.0.1", port);
    if socket.status == silly_transport::IoStatus.WouldBlock {
        body_socket::ready(socket.descriptor, silly_transport::WRITE, body_socket::now() + 10000);
        assert(silly_transport::finish_connect(socket.descriptor).status != silly_transport::IoStatus.Ready);
    } else {
        assert(socket.status != silly_transport::IoStatus.Ready);
    }
    silly_transport::close(socket.descriptor);
}
