// Every owner, slot and generation component gates adoption into reusable connection storage.
namespace executor_identity_test;

import silly from "..";

import std;

struct OwnerTag {
}

fn options() -> silly::ServerOptions {
    return silly::ServerOptions {
        limits: silly::Limits {
            head_bytes_max: 128,
            body_bytes_max: 32,
            output_bytes_max: 32,
            ..
        },
        connections_max: 1,
        response_head_bytes_max: 128,
        work_bytes_per_turn: 16,
        accepts_per_turn: 1,
        body_read_bytes_max: 16,
        ..
    };
}

fn reply() -> silly::ExecReply<OwnerTag> {
    return silly::ExecReply<OwnerTag> {
        key: silly::TransferKey {
            owner: 0,
            slot: 0,
            connection_generation: 7,
            request_generation: 9,
        },
        head: "response-head",
        body: "owned-result",
        ..
    };
}

fn reject_stale(storage: silly::ServerStorage&, config: silly::ServerOptions, owner: silly::ExecutorOwner&) {
    for field in 4 {
        var stale = reply();
        if field == 0 {
            stale.key.owner = 1;
        }
        if field == 1 {
            stale.key.slot = 1;
        }
        if field == 2 {
            stale.key.connection_generation = 6;
        }
        if field == 3 {
            stale.key.request_generation = 8;
        }
        assert(!silly::apply_executor_reply(storage, config, owner, stale, 10, silly::default_response_error));
        assert(storage.connections[0].phase == silly::ConnectionPhase.Executing);
        assert(storage.head[0] == 'h');
        assert(storage.body[0] == 'b');
    }
    storage.connections[0].phase = silly::ConnectionPhase.Reading;
    assert(!silly::apply_executor_reply(storage, config, owner, reply(), 10, silly::default_response_error));
    storage.connections[0].phase = silly::ConnectionPhase.Executing;
}

fn adopt_and_reuse(storage: silly::ServerStorage&, config: silly::ServerOptions, owner: silly::ExecutorOwner&) {
    let result = reply();
    assert(silly::apply_executor_reply(storage, config, owner, result, 10, silly::default_response_error));
    assert(storage.connections[0].phase == silly::ConnectionPhase.Writing);
    assert(storage.head[..result.head.len] == result.head);
    assert(storage.body[..result.body.len] == result.body);
    assert(!silly::apply_executor_reply(storage, config, owner, result, 10, silly::default_response_error));
    silly::reset_connection(storage.connections[0]);
    assert(storage.connections[0].request_generation == 10);
    storage.connections[0].phase = silly::ConnectionPhase.Executing;
    storage.connections[0].execution_deadline = 100;
    assert(!silly::apply_executor_reply(storage, config, owner, result, 10, silly::default_response_error));
    var next = result;
    next.key.request_generation = 10;
    assert(silly::apply_executor_reply(storage, config, owner, next, 10, silly::default_response_error));
    storage.connections[0].generation = 8;
    storage.connections[0].request_generation = 1;
    storage.connections[0].phase = silly::ConnectionPhase.Executing;
    assert(!silly::apply_executor_reply(storage, config, owner, next, 10, silly::default_response_error));
}

fn run() {
    var connections: silly::Connection[1] = [silly::Connection {
            generation: 7,
            request_generation: 9,
            slot: 0,
            execution_deadline: 100,
            phase: silly::ConnectionPhase.Executing,
            ..
        }];
    var input: u8[128] = [0; 128];
    var head: u8[128] = ['h'; 128];
    var body: u8[32] = ['b'; 32];
    var request: u8[32] = [0; 32];
    var staging: u8[16] = [0; 16];
    var fds: i32[3] = [-1; 3];
    var interests: i32[3] = [0; 3];
    var events: i32[3] = [0; 3];
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
    var owner = silly::ExecutorOwner {
        owner: 0,
        ..
    };
    let config = options();
    reject_stale(storage, config, owner);
    adopt_and_reuse(storage, config, owner);
}

fn::main() {
    executor_identity_test::run();
    print("executor stale owner, slot and request generations cannot alter reused storage");
}
