// A concrete thread bridge enters one lane; all endpoint callbacks run on its local app owner.
namespace silly;

import std;

import.executor;
import.executor_delivery;
import.executor_response;
import.lifecycle_driver;
import.runtime_control;
import.runtime_routes;

fn run_executor_lane<R, C, I, D, H, L>(start: LaneStart, seed: C) {
    run_executor_lane_with_errors<R>(start, seed, I, D, H, L, default_response_error);
}

fn run_executor_lane_with_errors<R, C, I, D, H, L, E>(start: LaneStart, seed: C) {
    var app = I(seed, Owner {
            id: start.lane,
            lane: start.lane,
            serialized_name: serialized_owner_name(start),
        });
    var entries: RouteEntry<R>[>..] = [];
    var segments: RouteSegment[>..] = [];
    var bytes: u8[>..] = [];
    var router = Router<R> {
        entries: entries,
        segments: segments,
        bytes: bytes,
        limits: start.server.route_limits,
        ..
    };
    D(router, app);
    let plan = prepare(router);
    run_prepared_executor_lane(start, plan, app, H, L, E);
}

fn run_prepared_executor_lane<R, A, H, L, E>(start: LaneStart, plan: RoutePlan<R>, app: A&) {
    var control = silly_transport::Descriptor {
        fd: start.wake
    };
    var hooks = HookState {
    };
    var driver = LifecycleDriver<R, A> {
        plan: plan,
        app: app,
        owner: Owner {
            id: start.lane,
            lane: start.lane,
            serialized_name: serialized_owner_name(start),
        },
        ..
    };
    var error = ServerError.None;
    let issue = if plan.issue.error != RouteError.None {
        plan.issue
    } else {
        runtime_execution_issue(plan, start.options)
    };
    if issue.error != RouteError.None {
        error = ServerError.Routes;
    } else {
        let started = observe_lifecycle(driver, ServerEvent.Start, L);
        hooks.failure = started;
        if started == HookResult.Ok {
            publish_executor_report(start.report_wake, ExecutorReport {
                    lane: start.lane,
                    ready: true,
                    ok: true,
                    ..
                });
            error = drive_executor_lane(start, driver, hooks, H, L, E);
        }
    }
    let stopped = observe_lifecycle(driver, ServerEvent.Stop, L);
    if hooks.failure == HookResult.Ok {
        hooks.failure = stopped;
    }
    silly_transport::close(control);
    publish_executor_report(start.report_wake, ExecutorReport {
            lane: start.lane,
            ok: error == ServerError.None && hooks.failure == HookResult.Ok,
            error: if error != ServerError.None || hooks.failure == HookResult.Ok {
                error
            } else {
                ServerError.Hook
            },
            route_issue: issue,
            hook_failure: hooks.failure,
            ..
        });
}

fn drive_executor_lane<R, A, H, L, E>(start: LaneStart, driver: LifecycleDriver<R, A> & ,
    hooks: HookState&) -> ServerError {
    if start.lane == 0 {
        return executor_lane_loop<ExecutorLane0>(start, driver, hooks, H, L, E);
    }
    if start.lane == 1 {
        return executor_lane_loop<ExecutorLane1>(start, driver, hooks, H, L, E);
    }
    if start.lane == 2 {
        return executor_lane_loop<ExecutorLane2>(start, driver, hooks, H, L, E);
    }
    return executor_lane_loop<ExecutorLane3>(start, driver, hooks, H, L, E);
}

fn executor_lane_loop<Tag, R, A, H, L, E>(start: LaneStart, driver: LifecycleDriver<R, A> & ,
    hooks: HookState&) -> ServerError {
    let control = silly_transport::Descriptor {
        fd: start.wake
    };
    let fds: i32[1] = [start.wake];
    let interests: i32[1] = [silly_transport::READ];
    var events: i32[1] = [0];
    while true {
        let notification = silly_transport::drain_wake(control);
        let stop, stopping = qpoll<LaneStop<Tag>>();
        if stopping || notification.status == silly_transport::IoStatus.Closed || hooks.failure != HookResult.Ok {
            quiesce_lane_submissions(start);
            abandon_lane_tasks<Tag>(start);
            return ServerError.None;
        }
        if notification.status != silly_transport::IoStatus.Ready
            && notification.status != silly_transport::IoStatus.WouldBlock
            && notification.status != silly_transport::IoStatus.Interrupted {
            abandon_lane_tasks<Tag>(start);
            return ServerError.Wake;
        }
        let task, present = qpoll<LaneTask<Tag>>();
        if present {
            let now = silly_transport::monotonic_ms();
            if now.status != silly_transport::IoStatus.Ready {
                deliver_lane_reply(start, LaneReply {
                        key: task.work.key,
                        outcome: ExecutionOutcome.Unavailable,
                        completion: task.work.completion,
                        ..
                    });
                abandon_lane_tasks<Tag>(start);
                return ServerError.Clock;
            }
            if now.count >= task.work.deadline_ms {
                deliver_lane_reply(start, LaneReply {
                        key: task.work.key,
                        outcome: ExecutionOutcome.Deadline,
                        completion: task.work.completion,
                        ..
                    });
            } else if !runtime_control_admit(start.control_epoch) {
                deliver_lane_reply(start, LaneReply {
                        key: task.work.key,
                        outcome: ExecutionOutcome.Abandoned,
                        completion: task.work.completion,
                        ..
                    });
            } else {
                let reply = execute_lane_work(start, task.work, driver, hooks, H, L, E);
                deliver_lane_reply(start, reply);
            }
            continue;
        }
        let ready = silly_transport::poll(fds, interests, events, start.server.poll_timeout_ms);
        if ready.status != silly_transport::IoStatus.Ready && ready.status != silly_transport::IoStatus.Interrupted {
            abandon_lane_tasks<Tag>(start);
            return ServerError.Poll;
        }
    }
    return ServerError.None;
}

// A permit acquired before gate closure may still be publishing its owned task.
// No application callback runs here. Cancellation/poison allows coordinated reclamation after all joins.
fn quiesce_lane_submissions(start: LaneStart) {
    let fds: i32[1] = [-1];
    let interests: i32[1] = [0];
    var events: i32[1] = [0];
    while runtime_control_submissions(start.control_epoch) > 0
        && runtime_control_stage(start.control_epoch) == 1 {
        silly_transport::poll(fds, interests, events, 1);
    }
}

fn abandon_lane_tasks<Tag>(start: LaneStart) {
    for index in start.options.queue_max {
        let task, present = qpoll<LaneTask<Tag>>();
        if !present {
            break;
        }
        deliver_lane_reply(start, LaneReply {
                key: task.work.key,
                outcome: ExecutionOutcome.Abandoned,
                completion: task.work.completion,
                ..
            });
    }
}

fn serialized_owner_name(start: LaneStart) -> u8[..64] {
    return if start.lane == 0 {
        start.options.serialized_name
    } else {
        []
    };
}
