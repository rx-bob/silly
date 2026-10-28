// Executable E10.S1 consumer fixture. Payloads and guards are deterministic examples.
// No business stores, credentials, migrations or native database handles are opened.
// Real native ownership remains demonstrated by examples/promptnook_contract/native_state.goose.
namespace promptnook_reference;

import routes from "../examples/promptnook_contract";
import silly from "..";

import std;

type Route = promptnook_contract::Route;
type AppState = promptnook_contract::App;
type Context = silly::Context<AppState, silly::NoStream>;

fn initialize(seed: i64, owner: silly::Owner) -> AppState {
    return AppState {
        native_owner: owner.is_serialized("promptnook_native"),
        ..
    };
}

fn routes(router: silly::Router<Route>&, app: AppState&) {
    router.execution(silly::Execution.Serialized {
            lane: "promptnook_native"
        });
    promptnook_contract::routes(router, app);
    // Explicit health/OPTIONS declarations stay inline. Domain fixtures inherit serialization.
    for index in router.entries.len {
        let entry = router.entries[index];
        let path = router.bytes[entry.path_start..entry.path_start + entry.path_bytes];
        let method = router.bytes[entry.method_start..entry.method_start + entry.method_bytes];
        if path == "/" || path == "/healthz" || method == "OPTIONS" {
            router.entries[index].options.execution = silly::ExecutionClass.Inline;
        }
    }
}

fn handle<C>(ctx: C&, route: Route) {
    if ctx.app.native_owner {
        assert(ctx.app.native_started);
    } else {
        assert(route == promptnook_contract::Route.Main);
    }
    promptnook_contract::handle(ctx, route);
}

fn lifecycle(app: AppState&, event: silly::Lifecycle<Route>) -> silly::HookResult {
    match event {
        Start start => {
            if start.owner.is_serialized("promptnook_native") {
                assert(app.native_owner);
                // Later port opens application native state here, including partial-start cleanup.
                app.native_started = true;
            }
        },
        Stop stop => {
            if stop.owner.is_serialized("promptnook_native") {
                app.native_started = false;
            }
        },
        _ => {
        },
    }
    return silly::HookResult.Ok;
}

thread_fn io_worker(start: silly::WorkerStart, seed: i64) {
    silly::run_runtime_worker<Route>(start, seed, initialize, routes, handle, lifecycle);
}

thread_fn native_lane(start: silly::LaneStart, seed: i64) {
    silly::run_executor_lane<Route>(start, seed, initialize, routes, handle, lifecycle);
}

// Caller owns signal policy; runtime consumes listener and shutdown reader.
// Incomplete results retain ownership in pending until resume_shutdown completes.
fn run(listener: silly_transport::Descriptor, wake: silly_transport::Descriptor,
    signal_token: i64 = 0) -> silly::ServerResult {
    let options = silly::RuntimeOptions {
        signal_token: signal_token,
        workers: 2,
        accept_queue_max: 4,
        connections_max: 32,
        worker: silly::WorkerOptions {
            limits: silly::Limits {
                head_bytes_max: 16384,
                body_bytes_max: 65536,
                output_bytes_max: 65536,
                ..
            },
            connections_max: 4,
            response_head_bytes_max: 16384,
            accepts_per_turn: 4,
            ..
        },
        executor: silly::ExecutorOptions {
            serialized_name: "promptnook_native",
            lanes: 1,
            ..
        },
        ..
    };
    return silly::run_runtime_with_executor(options, listener, wake, 0, io_worker, native_lane);
}

fn start() -> bool {
    var signals = silly::install_shutdown_signals();
    if !signals.ok {
        return false;
    }
    var listener = silly_transport::listen("127.0.0.1", 0, 16);
    var wake = silly_transport::wake_pair();
    if listener.status != silly_transport::IoStatus.Ready || wake.status != silly_transport::IoStatus.Ready {
        silly_transport::close(listener.descriptor);
        silly_transport::close(wake.reader);
        silly_transport::close(wake.writer);
        silly::uninstall_shutdown_signals(signals);
        return false;
    }
    let port = silly_transport::local_port(listener.descriptor);
    print("PromptNook inert API fixture on 127.0.0.1:", port.count);
    var result = run(listener.descriptor, wake.reader, signals.token);
    while result.pending.active {
        result = silly::resume_shutdown(result.pending, 1000);
    }
    silly_transport::close(wake.writer);
    let restored = silly::uninstall_shutdown_signals(signals);
    return result.ok && restored;
}

fn::main() {
    if !promptnook_reference::start() {
        print("PromptNook fixture failed");
        exit(1);
    }
}
