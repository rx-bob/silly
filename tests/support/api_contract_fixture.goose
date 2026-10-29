// Proof-local adapters only: static target call shapes, not production routing or serving.
namespace api_contract;

import silly from "../../";

import std;

struct Entry<R> {
    path: const u8[:],
    route: R,
}

struct Router<R> {
    entries: Entry<R>[..4] = [],
}

struct Owner {
    id: i64,
}

struct Completion<R> {
    route: R,
    status: i32,
}

enum Lifecycle<R> {
    Start {
        owner: Owner
    },
    HandlerFinished {
        completion: Completion<R>
    },
    TransferFinished {
        completion: Completion<R>
    },
    Stop {
        owner: Owner
    },
}

enum HookResult {
    Ok,
    Failed {
        message: u8[..64]
    },
}

fn get<R>(router: Router<R>&, path: u8[:], route: R) {
    assert(router.entries.len < router.entries.cap);
    router.entries.push(Entry<R> {
            path: path,
            route: route
        });
}

fn default_lifecycle<R>(app: silly::NoState&, event: Lifecycle<R>) -> HookResult {
    return HookResult.Ok;
}

// Three call-site arguments: options plus two compile-time callbacks.
fn serve<R, D, H>(options: silly::ServerOptions) -> silly::ServerResult {
    assert(silly::valid_server_options(options));
    var router = Router<R> {
    };
    D(router);
    assert(router.entries.len == 1);
    var app = silly::NoState {
    };
    drive_buffered(router, app, H) {
        owner,
        event => default_lifecycle<R>(owner, event)
    };
    return silly::ServerResult {
        ok: true,
        ..
    };
}

// Five call-site arguments: options, app, and three compile-time callbacks.
fn serve<R, A, D, H, L>(options: silly::ServerOptions, app: A&) -> silly::ServerResult {
    assert(silly::valid_server_options(options));
    var owned_app = app;
    var router = Router<R> {
    };
    D(router, owned_app);
    assert(router.entries.len == 1);
    drive_buffered(router, owned_app, H, L);
    return silly::ServerResult {
        ok: true,
        ..
    };
}

// Six call-site arguments: options, app, and four compile-time callbacks.
fn serve<R, A, S, D, H, P, L>(options: silly::ServerOptions, app: A&) -> silly::ServerResult {
    assert(silly::valid_server_options(options));
    var owned_app = app;
    var router = Router<R> {
    };
    D(router, owned_app);
    assert(router.entries.len == 1);
    drive_stream<R, A, S>(router, owned_app, H, P, L);
    return silly::ServerResult {
        ok: true,
        ..
    };
}

fn drive_buffered<R, A, H, L>(router: Router<R>&, app: A&) {
    let route = router.entries[0].route;
    assert(L(app, Lifecycle<R>.Start {
            owner: Owner {
                id: 0
            }
        }) == HookResult.Ok);
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
    {
        let request = silly::Request {
            method: "GET",
            target: router.entries[0].path,
            ..
        };
        var ctx = silly::Context<A,
        silly::NoStream> {
            request: request,
            response: response,
            app: app
        };
        H(ctx, route);
    }
    assert(response.phase == silly::ResponsePhase.Prepared);
    let completion = Completion<R> {
        route: route,
        status: response.status
    };
    assert(L(app, Lifecycle<R>.HandlerFinished {
            completion: completion
        }) == HookResult.Ok);
    assert(silly::commit_response(response) == silly::ResponseError.None);
    var transport = silly::MemoryTransport {
        capacity: 128,
        ..
    };
    assert(silly::drain_memory(transport, response, 128) == silly::DrainResult.Complete);
    assert(transport.bytes == "ok");
    assert(L(app, Lifecycle<R>.TransferFinished {
            completion: completion
        }) == HookResult.Ok);
    assert(L(app, Lifecycle<R>.Stop {
            owner: Owner {
                id: 0
            }
        }) == HookResult.Ok);
}

fn drive_stream<R, A, S, H, P, L>(router: Router<R>&, app: A&) {
    let route = router.entries[0].route;
    assert(L(app, Lifecycle<R>.Start {
            owner: Owner {
                id: 0
            }
        }) == HookResult.Ok);
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
    var pending = silly::StreamStart<S> {
    };
    {
        let request = silly::Request {
            method: "GET",
            target: router.entries[0].path,
            ..
        };
        var ctx = silly::Context<A,
        S> {
            request: request,
            response: response,
            app: app,
            stream_start: pending
        };
        H(ctx, route);
    }
    assert(pending.selected);
    assert(response.phase == silly::ResponsePhase.Prepared);
    let completion = Completion<R> {
        route: route,
        status: response.status
    };
    assert(L(app, Lifecycle<R>.HandlerFinished {
            completion: completion
        }) == HookResult.Ok);
    assert(silly::commit_response(response) == silly::ResponseError.None);
    verify_steps(pending.state, P);
    assert(L(app, Lifecycle<R>.TransferFinished {
            completion: completion
        }) == HookResult.Ok);
    assert(L(app, Lifecycle<R>.Stop {
            owner: Owner {
                id: 0
            }
        }) == HookResult.Ok);
}

// Calls happen after the handler/context block ended. Input/output are only step-local views.
fn verify_steps<S, P>(state: S&) {
    var bytes: u8[64] = [0; 64];
    var out = silly::ChunkWriter {
        bytes: bytes,
        ..
    };
    match P(state, silly::StreamEvent.Ready, out) {
        Wait wait => {
            match wait.wake {
                After timer => {
                    assert(timer.delay_ms == 5);
                },
                _ => {
                    assert(false);
                },
            }
        },
        _ => {
            assert(false);
        },
    }
    match P(state, silly::StreamEvent.Input {
            bytes: "input"
        }, out) {
        Chunk chunk => {
            assert(chunk.flush);
            assert(chunk.next == silly::Wake.Input);
            assert(bytes[..out.used] == "owned:input");
        },
        _ => {
            assert(false);
        },
    }
    var failed = state;
    var cancelled = state;
    assert(P(state, silly::StreamEvent.InputEnd, out) == silly::StreamStep.Done);
    match P(failed, silly::StreamEvent.InputFailed {
            reason: silly::StreamError.Input
        }, out) {
        Failed failure => {
            assert(failure.reason == silly::StreamError.Input);
        },
        _ => {
            assert(false);
        },
    }
    assert(P(cancelled, silly::StreamEvent.Cancelled, out) == silly::StreamStep.Done);
}
