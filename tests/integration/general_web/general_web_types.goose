// One public-API application composes buffered pages with several owned stream producers.
namespace general_web;

import silly from "../../../";

enum Route {
    Page,
    Form,
    Json,
    File,
    Upload,
    Download,
    Events,
    Waiting
}
struct App {
    executor: silly::FileExecutor,
    root: silly::FileRoot,
    name: u8[..64] = [],
    handlers: i64 = 0,
    completed: i64 = 0,
    stopped: bool = false,
}
struct State {
    route: Route = Route.Download,
    file: silly::FileTransfer = silly::FileTransfer {
    },
    resource: silly_transport::Descriptor = silly_transport::Descriptor {
    },
    released: bool = false,
    bytes: i64 = 0,
    calls: i64 = 0,
    failed: bool = false,
    last_id: u8[..32] = [],
}
type Context = silly::Context<App, State>;
struct Started {
    ok: bool = true
}
struct Stopped {
    ok: bool,
    handlers: i64,
    completed: i64,
    stopped: bool
}
struct Acquired {
    route: Route,
    peer: i32
}
struct Released {
    route: Route,
    cancelled: bool,
    bytes: i64,
    failed: bool
}
struct Waiting {
    ok: bool = true
}
struct Input {
    name: const u8[:]
}
