// Static validator runs on opened-file metadata before conditional response selection.
namespace ranges_server;

import silly from "..";

import std;

struct App {
    executor: silly::FileExecutor,
    root: silly::FileRoot
}
enum Route {
    File
}
struct Started {
    ok: bool = true
}
struct Stopped {
    ok: bool
}
type Context = silly::Context<App, silly::FileTransfer>;
fn routes(router: silly::Router<Route>&, app: App&) {
    router.get("/*path", Route.File);
    router.head("/*path", Route.File);
    router.post("/*path", Route.File);
}

fn handle(ctx: Context&, route: Route) {
    let name = ctx.param("path");
    assert(name.present);
    let special = name.value == "disabled.html" || name.value == "limited.html";
    var opened = silly::open_file(ctx.app.executor, ctx.app.root, if special {
            "index.html"
        } else {
            name.value
        });
    assert(opened.ok);
    assert(silly::static_file_response(ctx, opened.file, name.value, silly::StaticFileOptions {
            ranges: name.value != "disabled.html",
            ranges_max: if name.value == "limited.html" {
                1
            } else {
                16
            },
            pending_bytes_max: 3,
            ..
        }) == silly::ResponseError.None);
    assert(opened.file.token == 0);
}

fn validator(metadata: silly::FileMetadata) -> silly::FileValidator {
    if metadata.size == 9 {
        return silly::default_file_validator(metadata);
    }
    var result = silly::FileValidator {
        last_modified_strong: true,
        ..
    };
    result.etag.append(str("\"range-", metadata.size, "\""));
    return result;
}

fn step(state: silly::FileTransfer&, event: silly::StreamEvent, out: silly::ChunkWriter&) -> silly::StreamStep {
    return silly::file_step_with_validator(state, event, out, validator);
}

fn lifecycle(app: App&, event: silly::Lifecycle<Route>) -> silly::HookResult {
    match event {
        Start _ => {
            assert(qput(Started {
                }));
        },
        _ => {
        },
    }
    return silly::HookResult.Ok;
}

thread_fn server(listener: i32, wake: i32, executor: silly::FileExecutor, root: silly::FileRoot) {
    var app = App {
        executor: executor,
        root: root
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
    let options = silly::ServerOptions {
        limits: silly::Limits {
            body_bytes_max: 0,
            output_bytes_max: 32,
            ..
        },
        connections_max: 2,
        response_head_bytes_max: 1024,
        work_bytes_per_turn: 2,
        accepts_per_turn: 2,
        poll_timeout_ms: 10,
        ..
    };
    let result = silly::run_prepared_stream_server<Route, App, silly::FileTransfer>(options,
        silly_transport::Descriptor {
            fd: listener
        }, silly_transport::Descriptor {
            fd: wake
        },
        silly::prepare(router), app, handle, step, lifecycle);
    assert(qput(Stopped {
            ok: result.ok
        }));
}
