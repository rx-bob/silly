// Deterministic work-budget rotation and deadline selection without sleep races.
namespace runtime_scheduler_test;

import silly from "..";

import std;

const EMPTY_ENTRIES: silly::RouteEntry<i32>[0] = [];
const EMPTY_SEGMENTS: silly::RouteSegment[0] = [];

struct Counts {
    delivered: i64 = 0,
    order: i64 = 0,
}

fn observe(driver: silly::RouteDriver<i32, Counts> & , event: silly::ServerEvent) -> silly::HookResult {
    let counts .= driver.app;
    match event {
        TransferFinished done => {
            assert(done.completion.transfer == silly::TransferOutcome.Delivered);
            counts.delivered += 1;
            counts.order = counts.order * 10 + done.completion.route_id;
        },
        _ => {
        },
    }
    return silly::HookResult.Ok;
}

fn unused_handler(driver: silly::RouteDriver<i32, Counts> & , ctx: silly::BufferedContext&) {
    assert(false);
}

fn fixture() {
    let options = silly::ServerOptions {
        limits: silly::Limits {
            head_bytes_max: 64,
            body_bytes_max: 0,
            output_bytes_max: 256,
            ..
        },
        connections_max: 3,
        response_head_bytes_max: 128,
        accepts_per_turn: 3,
        dispatches_per_turn: 1,
        idle_timeout_ms: 100,
        poll_timeout_ms: 100,
        body_read_bytes_max: 64,
        ..
    };
    var connections: silly::Connection[3] = [silly::Connection {
        }; 3];
    var input: u8[192] = [0; 192];
    var head: u8[384] = [0; 384];
    var body: u8[768] = [0; 768];
    var request: u8[0] = [];
    var staging: u8[192] = [0; 192];
    var fds: i32[5] = [-1; 5];
    var interests: i32[5] = [0; 5];
    var events: i32[5] = [0; 5];
    var hooks = silly::HookState {
    };
    var storage = silly::ServerStorage {
        connections: connections,
        input: input,
        head: head,
        body: body,
        request: request,
        staging: staging,
        fds: fds,
        interests: interests,
        events: events,
        hooks: hooks,
        ..
    };
    exercise(storage, options);
}

fn exercise(storage: silly::ServerStorage&, options: silly::ServerOptions) {
    var counts = Counts {
    };
    var driver = silly::RouteDriver<i32, Counts> {
        plan: empty_plan(),
        app: counts
    };
    for index in 3 {
        storage.connections[index] = silly::Connection {
            phase: silly::ConnectionPhase.Writing,
            active_ms: 100,
            completion: silly::CompletionData {
                route_id: index + 1,
                ..
            },
            completion_pending: true,
            ..
        };
        storage.events[index + 2] = silly_transport::WRITE;
    }
    // Empty output completes without a syscall. At most one terminal callback per turn.
    for turn in 3 {
        silly::service_connections(storage, options, 101, driver,
            unused_handler, silly::default_response_error, observe);
        assert(counts.delivered == turn + 1);
        assert(storage.service_cursor == (turn + 1) % 3);
        assert(storage.service_pending == (turn < 2));
    }
    assert(counts.order == 123);
    assert(silly::server_poll_deadline(storage, options, 190) == 100);
    storage.connections[0] = silly::Connection {
        phase: silly::ConnectionPhase.Reading,
        active_ms: 100,
        ..
    };
    assert(silly::server_poll_deadline(storage, options, 190) == 10);
    assert(silly::server_poll_deadline(storage, options, 200) == 0);
    assert(silly::server_poll_deadline(storage, options, 99) == 0);
    storage.connections[0].staged_bytes = 1;
    assert(silly::server_poll_deadline(storage, options, 101) == 0);
    storage.connections[0].staged_bytes = 0;
    storage.service_pending = true;
    assert(silly::server_poll_deadline(storage, options, 101) == 0);
    storage.service_pending = false;
    assert(silly::server_poll_deadline(storage, options, 101) == 99);
    stalled_slot(storage, options);
}

fn stalled_slot(storage: silly::ServerStorage&, options: silly::ServerOptions) {
    var counts = Counts {
    };
    var driver = silly::RouteDriver<i32, Counts> {
        plan: empty_plan(),
        app: counts
    };
    storage.connections[0].phase = silly::ConnectionPhase.Writing;
    storage.events[2] = 0;
    storage.connections[1] = silly::Connection {
        phase: silly::ConnectionPhase.Writing,
        active_ms: 100,
        completion: silly::CompletionData {
            route_id: 2,
            ..
        },
        completion_pending: true,
        ..
    };
    storage.events[3] = silly_transport::WRITE;
    storage.service_cursor = 0;
    silly::service_connections(storage, options, 101, driver,
        unused_handler, silly::default_response_error, observe);
    assert(counts.delivered == 1);
    assert(counts.order == 2);
    assert(storage.connections[0].phase == silly::ConnectionPhase.Writing);
    assert(!storage.service_pending);
}

fn empty_plan() -> silly::RoutePlan<i32> {
    return silly::RoutePlan<i32> {
        entries: EMPTY_ENTRIES,
        segments: EMPTY_SEGMENTS,
        bytes: "",
        limits: silly::RouteLimits {
        },
        issue: silly::RouteIssue {
        },
        ..
    };
}

fn::main() {
    runtime_scheduler_test::fixture();
    print("runtime_scheduler_test: ok");
}
