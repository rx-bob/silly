// Nested endpoint guards unwind once; cleanup runs after every handler outcome.
namespace endpoint_test;

import silly from "..";

import std;

struct App {
    ready: bool = true,
    session: bool = true,
    allowed: bool = true,
    stage: i64 = 0,
    cleanups: i64 = 0,
    failed: bool = false,
}
type Context = silly::Context<App, silly::NoStream>;
enum Route {
    Normal,
    Empty,
    RejectEmpty,
    Missing,
    Cancel,
    Duplicate,
    Custom,
    Overflow,
    Unprepared,
    Failed,
}

fn require_database(ctx: Context&) {
    if !ctx.app.ready {
        ctx.reject_text(503, "database unavailable");
    }
}

fn require_session(ctx: Context&) {
    require_database(ctx);
    if !ctx.app.session {
        silly::reject_text(ctx, 401, "session required");
    }
}

fn require_permission(ctx: Context&) {
    require_session(ctx);
    if !ctx.app.allowed {
        silly::reject_text(ctx, 403, "permission denied");
    }
}

fn handle(ctx: Context&, route: Route) {
    ctx.app.stage = 1;
    require_permission(ctx);
    ctx.app.stage = 2;
    match route {
        Normal => {
            assert(silly::respond_text(ctx, 200, "ok") == silly::ResponseError.None);
        },
        Empty => {
            assert(ctx.respond_empty(204) == silly::ResponseError.None);
        },
        RejectEmpty => {
            ctx.reject_empty(403);
            ctx.app.stage = 99;
        },
        Missing => {
        },
        Cancel => {
            silly::cancel_response(ctx.response, silly::ResponseError.Application);
        },
        Duplicate => {
            assert(ctx.respond_empty(204) == silly::ResponseError.None);
            silly::reject_text(ctx, 403, "second response");
            ctx.app.stage = 99;
        },
        Custom => {
            assert(silly::begin_response(ctx.response, 401) == silly::ResponseError.None);
            assert(silly::add_header(ctx.response, "Content-Type", "application/json") == silly::ResponseError.None);
            assert(silly::append_body(ctx.response, "{\"error\":\"custom\"}") == silly::ResponseError.None);
            assert(silly::prepare_response(ctx.response) == silly::ResponseError.None);
            ctx.reject();
            ctx.app.stage = 99;
        },
        Unprepared => {
            ctx.reject();
            ctx.app.stage = 99;
        },
        Failed => {
            silly::fail_response(ctx.response, silly::ResponseError.Application);
            ctx.reject();
            ctx.app.stage = 99;
        },
        Overflow => {
            let large: u8[128] = ['x'; 128];
            silly::reject_text(ctx, 503, large);
            ctx.app.stage = 99;
        },
    }
}

fn cleanup(app: App&, outcome: silly::HandlerOutcome) {
    assert(app.cleanups == 0);
    assert(app.stage == 1 || app.stage == 2);
    app.cleanups += 1;
    match outcome {
        Failed _ => {
            app.failed = true;
        },
        _ => {
        },
    }
    app.stage += 10;
}

fn verify(app: App&, route: Route, status: i32, payload: u8[:], stage: i64) {
    let request = silly::Request {
        method: "GET",
        target: "/",
        ..
    };
    var fields: silly::HeaderField[>..] = [];
    var headers: u8[>..] = [];
    var output: u8[>..] = [];
    var response = silly::Response {
        limits: silly::Limits {
            output_bytes_max: 64,
            ..
        },
        header_fields: fields,
        header_bytes: headers,
        output: output,
        ..
    };
    var ctx = Context {
        request: request,
        response: response,
        app: app,
        ..
    };
    let outcome = silly::coordinate_endpoint(ctx, route, handle, cleanup);
    assert(app.cleanups == 1);
    assert(app.stage == stage);
    assert(response.status == status);
    assert(output == payload);
    match outcome {
        Prepared => {
            assert(!app.failed);
        },
        MissingResponse => {
            assert(route == Route.Missing);
        },
        Failed failure => {
            assert(app.failed);
            assert(failure.error == response.error);
        },
        _ => {
            assert(false);
        },
    }
    if route == Route.Unprepared {
        assert(response.error == silly::ResponseError.InvalidState);
    }
    if route == Route.Failed || route == Route.Cancel {
        assert(response.error == silly::ResponseError.Application);
    }
    if route == Route.Cancel {
        assert(response.phase == silly::ResponsePhase.Cancelled);
    }
    if route == Route.Duplicate {
        assert(response.error == silly::ResponseError.AlreadyStarted);
    }
    if route == Route.Overflow {
        assert(response.error == silly::ResponseError.OutputLimit);
    }
}

fn local_response(text: bool) {
    let request = silly::Request {
        method: "GET",
        target: "/",
        ..
    };
    var fields: silly::HeaderField[>..] = [];
    var headers: u8[>..] = [];
    var output: u8[>..] = [];
    var response = silly::Response {
        limits: silly::Limits {
        },
        header_fields: fields,
        header_bytes: headers,
        output: output,
        ..
    };
    var app = App {
    };
    var ctx = Context {
        request: request,
        response: response,
        app: app,
        ..
    };
    if text {
        assert(ctx.respond_text(200, "outside boundary") == silly::ResponseError.None);
        assert(output == "outside boundary");
    } else {
        assert(ctx.respond_empty(204) == silly::ResponseError.None);
        assert(output.len == 0);
        assert(response.phase == silly::ResponsePhase.Prepared);
    }
    assert(app.cleanups == 0);
}

fn run() {
    local_response(true);
    local_response(false);
    var normal = App {
    };
    verify(normal, Route.Normal, 200, "ok", 12);
    var empty = App {
    };
    verify(empty, Route.Empty, 204, "", 12);
    var rejected_empty = App {
    };
    verify(rejected_empty, Route.RejectEmpty, 403, "", 12);
    var missing = App {
    };
    verify(missing, Route.Missing, 0, "", 12);
    var cancel = App {
    };
    verify(cancel, Route.Cancel, 0, "", 12);
    var duplicate = App {
    };
    verify(duplicate, Route.Duplicate, 204, "", 12);
    var custom = App {
    };
    verify(custom, Route.Custom, 401, "{\"error\":\"custom\"}", 12);
    var unprepared = App {
    };
    verify(unprepared, Route.Unprepared, 0, "", 12);
    var failed = App {
    };
    verify(failed, Route.Failed, 0, "", 12);
    var overflow = App {
    };
    verify(overflow, Route.Overflow, 503, "", 12);
    var db = App {
        ready: false,
        ..
    };
    verify(db, Route.Normal, 503, "database unavailable", 11);
    var session = App {
        session: false,
        ..
    };
    verify(session, Route.Normal, 401, "session required", 11);
    var permission = App {
        allowed: false,
        ..
    };
    verify(permission, Route.Normal, 403, "permission denied", 11);
    print("endpoint guards and completion order passed");
}

fn::main() {
    endpoint_test::run();
}
