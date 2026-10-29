// Deterministic local upstream; a queue gate proves Portal I/O can progress independently.
namespace portal_upstream;

import silly from "../../../";

import std;

struct Started {
    ok: bool = true
}
struct Stopped {
    ok: bool
}
struct Holding {
    ok: bool = true
}
struct Release {
    ok: bool = true
}
enum Route {
    Echo
}
type Context = silly::Context<silly::NoState, silly::NoStream>;

fn handle(ctx: Context&, route: Route) {
    if ctx.request.target == "/api/admin/hold" {
        assert(qput(Holding {
            }));
        let released, present = qget<Release>(10000);
        assert(present);
    }
    let expected: u8[5] = ['a', 0, 255, '\r', '\n'];
    if ctx.request.method == "POST" {
        assert(ctx.body() == expected);
    }
    assert(ctx.header("Authorization").value == "Bearer fixture-token");
    assert(ctx.header("Host").value == "portal.test");
    assert(!ctx.header("X-Hop").present);
    assert(silly::begin_response(ctx.response, 201) == silly::ResponseError.None);
    assert(silly::add_header(ctx.response, "X-Upstream", "fixture") == silly::ResponseError.None);
    assert(silly::append_body(ctx.response, str(ctx.request.method, " ", ctx.request.target))
        == silly::ResponseError.None);
    assert(silly::prepare_response(ctx.response) == silly::ResponseError.None);
}

fn lifecycle(app: silly::NoState&, event: silly::Lifecycle<Route>) -> silly::HookResult {
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
thread_fn server(listener: i32, wake: i32) {
    var entries: silly::RouteEntry<Route>[>..] = [];
    var segments: silly::RouteSegment[>..] = [];
    var bytes: u8[>..] = [];
    var router = silly::Router<Route> {
        entries: entries,
        segments: segments,
        bytes: bytes,
        ..
    };
    router.any("/*path", Route.Echo);
    var app = silly::NoState {
    };
    let result = silly::run_prepared_server_with_lifecycle(silly::ServerOptions {
            poll_timeout_ms: 10,
            ..
        },
        silly_transport::Descriptor {
            fd: listener
        }, silly_transport::Descriptor {
            fd: wake
        },
        silly::prepare(router), app, handle, lifecycle);
    assert(qput(Stopped {
            ok: result.ok
        }));
}
