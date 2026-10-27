namespace portal_server;

import silly from "..";

import std;

struct App {
    executor: silly::FileExecutor,
    root: silly::FileRoot
}
enum Route {
    Static
}
struct Started {
    ok: bool = true
}
struct Stopped {
    ok: bool
}
type Context = silly::Context<App, silly::StaticTransfer>;

fn handle(ctx: Context&, route: Route) {
    var mount = silly::FileMount {
        executor: ctx.app.executor,
        root: ctx.app.root,
        directory_policy: silly::DirectoryPolicy.List,
        missing_policy: silly::MissingFilePolicy.RootListing,
        gzip_freshness_ms: 10,
        pending_bytes_max: 7,
        ..
    };
    var path: u8[>..] = [];
    if ctx.request.target == "/cap-entries" {
        mount.entries_max = 1;
        path.append("/");
    } else if ctx.request.target == "/cap-output" {
        mount.output_bytes_max = 32;
        path.append("/");
    } else if ctx.request.target == "/cap-names" {
        mount.listing_bytes_max = 8;
        path.append("/");
    } else if ctx.request.target == "/strict-near" {
        mount.gzip_freshness_ms = 0;
        path.append("/near.txt");
    }
    assert(silly::static_mount_response(ctx, mount, path) == silly::ResponseError.None);
}

fn validator(metadata: silly::FileMetadata) -> silly::FileValidator {
    var result = silly::FileValidator {
        last_modified_strong: true,
        ..
    };
    result.etag.append(str("\"portal-", metadata.size, "\""));
    return result;
}

fn policy(event: silly::StaticLookupEvent) -> silly::StaticAction {
    if event.path == "/index/" || event.path == "/spa-missing" || event.path == "/loop" {
        var action = silly::StaticAction {
            kind: silly::StaticActionKind.ServePath,
            ..
        };
        action.path.append(if event.path == "/index/" {
                "/index/index.html"
            } else if event.path == "/loop" {
                "/loop"
            } else {
                "/index.html"
            });
        return action;
    }
    if event.path == "/reject" {
        return silly::StaticAction {
            kind: silly::StaticActionKind.Reject,
            status: 404,
            ..
        };
    }
    return silly::default_static_policy(event);
}

fn step(state: silly::StaticTransfer&, event: silly::StreamEvent, out: silly::ChunkWriter&) -> silly::StreamStep {
    return silly::static_file_step_with_policy(state, event, out, validator, policy);
}

fn lifecycle(app: App&, event: silly::Lifecycle<Route>) -> silly::HookResult {
    match event {
        Start _ => {
            assert(qput(Started {
                }));
        },
        _ => {
        }
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
    router.any("/*path", Route.Static);
    let options = silly::ServerOptions {
        limits: silly::Limits {
            body_bytes_max: 0,
            output_bytes_max: 32,
            ..
        },
        connections_max: 2,
        response_head_bytes_max: 2048,
        work_bytes_per_turn: 7,
        accepts_per_turn: 2,
        poll_timeout_ms: 10,
        ..
    };
    let result = silly::run_prepared_stream_server<Route, App, silly::StaticTransfer>(options,
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
