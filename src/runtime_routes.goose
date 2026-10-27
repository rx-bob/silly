// Concrete application thread entrypoints call this adapter to build entirely local owners.
namespace silly;

import std;

import.execution_types;
import.executor_types;
import.lifecycle_driver;
import.lifecycle_types;
import.response_errors;
import.route_lifecycle;
import.route_plan;
import.route_server;
import.route_types;
import.router;
import.server_buffers;
import.server_options;
import.transport;
import.worker;
import.worker_message;
import.worker_options;

// Goose thread_fn cannot be generic: the application supplies one concrete top-level thread_fn.
// Its arguments are owned launch data WorkerStart and flat seed C.
fn run_runtime_worker<R, C, I, D, H, L>(start: WorkerStart, seed: C) {
    run_runtime_worker_with_errors<R>(start, seed, I, D, H, L, default_response_error);
}

fn run_runtime_worker_with_errors<R, C, I, D, H, L, E>(start: WorkerStart, seed: C) {
    let owner = start.owner;
    var app = I(seed, Owner {
            id: start.owner
        });
    let options = worker_server_options(start.options);
    let result = if owner == 0 {
        runtime_local_routes<IoOwner0, R>(options, start, app, D, H, L, E)
    } else if owner == 1 {
        runtime_local_routes<IoOwner1, R>(options, start, app, D, H, L, E)
    } else if owner == 2 {
        runtime_local_routes<IoOwner2, R>(options, start, app, D, H, L, E)
    } else {
        runtime_local_routes<IoOwner3, R>(options, start, app, D, H, L, E)
    };
    // Capacity reserves two reports per worker, and the runtime lease excludes another producer set.
    publish_worker_report(start.report_wake, worker_report(owner, result));
}

fn runtime_local_routes<Tag, R, A, D, H, L, E>(options: ServerOptions,
    start: WorkerStart, app: A&) -> ServerResult {
    var entries: RouteEntry<R>[>..] = [];
    var segments: RouteSegment[>..] = [];
    var bytes: u8[>..] = [];
    var router = Router<R> {
        entries: entries,
        segments: segments,
        bytes: bytes,
        limits: options.route_limits,
        ..
    };
    D(router, app);
    var plan = prepare(router);
    if plan.issue.error == RouteError.None {
        plan.issue = runtime_execution_issue(plan, start.executor.lanes);
    }
    if plan.issue.error != RouteError.None {
        var control = silly_transport::Descriptor {
            fd: start.wake
        };
        // Initialization already created an app owner. Stop releases it even without a valid plan/Start.
        var result = route_failure(plan.issue);
        result.hook_failure = L(app, Lifecycle<R>.Stop {
                owner: Owner {
                    id: start.owner
                }
            });
        silly_transport::close(control);
        return result;
    }
    var driver = LifecycleDriver<R, A> {
        plan: plan,
        app: app,
        executor: ExecutorOwner {
            options: start.executor,
            owner: start.owner,
            lane_writers: start.lane_writers,
            ..
        },
        owner: Owner {
            id: start.owner
        },
    };
    fn dispatch(routes: LifecycleDriver<R, A> & , ctx: BufferedContext&) {
        dispatch_lifecycle_route(routes, ctx, H);
    }

    fn observe(routes: LifecycleDriver<R, A> & , event: ServerEvent) -> HookResult {
        let result = observe_lifecycle(routes, event, L);
        if event == ServerEvent.Start && result == HookResult.Ok {
            publish_worker_report(start.report_wake, WorkerReport {
                    owner: routes.owner.id,
                    ready: true,
                    ok: true,
                    ..
                });
        }
        return result;
    }
    return run_worker_state<Tag>(options, silly_transport::Descriptor {
            fd: start.wake
        }, driver, E, dispatch, observe);
}

fn runtime_execution_issue<R>(plan: RoutePlan<R>, lanes: i64) -> RouteIssue {
    for index in plan.entries.len {
        match plan.entries[index].options.execution {
            Lane selected => {
                if selected.index < 0 || selected.index >= lanes {
                    return RouteIssue {
                        error: RouteError.UnsupportedOptions,
                        route_id: index,
                        ..
                    };
                }
            },
            Inline => {
            },
        }
    }
    return RouteIssue {
    };
}
