// One real listener hosts the composed general-web handlers and owned producers.
namespace general_web;

import silly from "../../../";

import std;

import.general_web_handlers;
import.general_web_steps;
import.general_web_types;

thread_fn serve(listener: i32, wake: i32, executor: silly::FileExecutor, root: silly::FileRoot) {
    var app = App {
        executor: executor,
        root: root,
        ..
    };
    var entries: silly::RouteEntry<Route>[>..] = [];
    var segments: silly::RouteSegment[>..] = [];
    var bytes: u8[>..] = [];
    var router = silly::Router<Route> {
        entries: entries,
        segments: segments,
        bytes: bytes,
        ..
    };
    routes(router, app);
    let plan = silly::prepare(router);
    assert(plan.issue.error == silly::RouteError.None);
    let options = silly::ServerOptions {
        limits: silly::Limits {
            body_bytes_max: 128,
            output_bytes_max: 512,
            ..
        },
        connections_max: 3,
        response_head_bytes_max: 512,
        work_bytes_per_turn: 31,
        accepts_per_turn: 3,
        poll_timeout_ms: 10,
        body_limits: silly::BodyLimits {
            bytes_max: 1024,
            ..
        },
        body_read_bytes_max: 31,
        ..
    };
    let result = silly::run_prepared_stream_server<Route, App, State>(options,
        silly_transport::Descriptor {
            fd: listener
        }, silly_transport::Descriptor {
            fd: wake
        },
        plan, app, handle, step, lifecycle);
    assert(qput(Stopped {
            ok: result.ok,
            handlers: app.handlers,
            completed: app.completed,
            stopped: app.stopped
        }));
}
