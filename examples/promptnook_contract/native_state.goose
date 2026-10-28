// Executable ownership contract, not a production Turso/ZIP binding or PromptNook business port.
// The integration fixture supplies these adapters only in tests/native_state_test.build.
namespace promptnook_native_example;

import silly from "../..";

import std;

import.native_bindings;

enum Route {
    Health,
    DatabaseFirst,
    DatabaseSecond,
    ExportFirst,
    ExportSecond
}
struct App {
    owner: silly::Owner,
    owns_native: bool,
    opened: bool = false,
}

fn initialize(seed: i64, owner: silly::Owner) -> App {
    return App {
        owner: owner,
        owns_native: owner.is_serialized("promptnook_native"),
        ..
    };
}

fn routes(router: silly::Router<Route>&, app: App&) {
    router.get("/health", Route.Health);
    router.scope("/api") {
        api =>
        api.execution(silly::Execution.Serialized {
                lane: "promptnook_native"
            });
        api.get("/db/first", Route.DatabaseFirst);
        api.get("/db/second", Route.DatabaseSecond);
        api.get("/export/first", Route.ExportFirst);
        api.get("/export/second", Route.ExportSecond);
    };
}

fn handle(ctx: silly::Context<App, silly::NoStream> & , route: Route) {
    if route == Route.Health {
        assert(!ctx.app.owns_native);
        ctx.text(200, "healthy");
        return;
    }
    assert(ctx.app.owns_native);
    assert(ctx.app.opened);
    // Keep each complete sequence inside this one lane invocation.
    if route == Route.DatabaseFirst || route == Route.DatabaseSecond {
        let value: i64 = if route == Route.DatabaseFirst {
            11
        } else {
            22
        };
        assert(promptnook_contract_prepare(value) == 0);
        assert(promptnook_contract_bind(value) == 0);
        assert(promptnook_contract_query() == 0);
        let result = promptnook_contract_read();
        assert(result >= 0);
        ctx.text(200, str("db:", result));
    } else {
        let value: i64 = if route == Route.ExportFirst {
            33
        } else {
            44
        };
        assert(promptnook_contract_zip_reset(value) == 0);
        assert(promptnook_contract_zip_add(value) == 0);
        let result = promptnook_contract_zip_finish();
        assert(result >= 0);
        ctx.text(200, str("zip:", result));
    }
}

fn lifecycle(app: App&, event: silly::Lifecycle<Route>) -> silly::HookResult {
    match event {
        Start start => {
            if app.owns_native {
                assert(start.owner.is_serialized("promptnook_native"));
                if promptnook_contract_open() != 0 {
                    return silly::HookResult.Failed {
                        message: "native state open failed"
                    };
                }
                app.opened = true;
            }
        },
        Stop stop => {
            if app.opened {
                assert(stop.owner.is_serialized("promptnook_native"));
                assert(promptnook_contract_close() == 0);
                app.opened = false;
            }
        },
        _ => {
        },
    }
    return silly::HookResult.Ok;
}

// Copy startup configuration into owners; never pass native global handles between threads.
fn options(timeout_ms: i64 = 10000) -> silly::RuntimeOptions {
    return silly::RuntimeOptions {
        workers: 2,
        accept_queue_max: 4,
        worker: silly::WorkerOptions {
            limits: silly::Limits {
                head_bytes_max: 2048,
                body_bytes_max: 2048,
                output_bytes_max: 2048,
                ..
            },
            connections_max: 4,
            response_head_bytes_max: 2048,
            accepts_per_turn: 1,
            dispatches_per_turn: 1,
            idle_timeout_ms: 15000,
            poll_timeout_ms: 10,
            ..
        },
        executor: silly::ExecutorOptions {
            serialized_name: "promptnook_native",
            lanes: 1,
            queue_max: 4,
            outstanding_per_owner: 4,
            head_bytes_max: 1024,
            body_bytes_max: 512,
            response_head_bytes_max: 1024,
            response_body_bytes_max: 512,
            task_timeout_ms: timeout_ms,
            ..
        },
        ..
    };
}
