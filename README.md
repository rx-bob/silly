<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/logo_main.png">
    <img src="assets/logo_light_bg.png" alt="Silly" width="320">
  </picture>
</p>

## What is Silly?

`silly` is an HTTP/1.0 and HTTP/1.1 library for [Goose](https://aardappel.github.io/goose/) (`v2026.3`) on Linux and macOS. Applications own `main`, configuration, and lifecycle policy while `silly` handles wire framing, routing, and bounded resource budgets:

- **Prepared typed routing**: Declare routes once at startup into a validated static dispatch plan—no request-time route registration or heap closures.
- **Explicit memory & work budgets**: Finite connection slots, request/response limits, and per-turn work caps verified before the listener accepts traffic.
- **Owned streaming & optional client**: First-class chunked streams, SSE, rooted static file serving with range/gzip support, and an optional `libcurl`/`zlib` HTTP/HTTPS client and reverse proxy package.

## Installation

Requires [Goose v2026.3](https://aardappel.github.io/goose/) and a C compiler with platform socket/threading libraries (`libcurl` and `zlib` are only needed when importing `silly/client`).

Clone `silly` alongside your application checkout (or try the bundled reference server directly):

```sh
git clone https://github.com/rx-bob/silly.git
cd silly
goose build reference/app.goose --offline -O2 -o /tmp/silly-app
/tmp/silly-app
```

## Configuration

Configure listener bindings, connection budgets, timeouts, and payload caps with `silly::ServerOptions` and `silly::Limits`. Invalid budgets fail fast at startup:

```goose
let options = silly::ServerOptions {
    address: "127.0.0.1",
    port: 8081,
    connections_max: 16,
    idle_timeout_ms: 30000,
    limits: silly::Limits {
        head_bytes_max: 32 * 1024,
        body_bytes_max: 8 * 1024 * 1024,
        output_bytes_max: 8 * 1024 * 1024,
        ..
    },
    ..
};
```

Core server imports compile their native transport and file helpers automatically via `silly.build`. If your application also imports `silly/client`, add a `<app>.build` sidecar next to your entry point:

```text
c_sources = ["../silly/client/native/client.c"];
c_libs = ["curl", "z"];
```

## Usage

Import `silly` from a sibling directory, define a `Route` enum, register routes, and dispatch matched requests in your handler:

```goose
namespace demo;

import silly from "../silly";

import std;

type Context = silly::Context<silly::NoState, silly::NoStream>;

enum Route {
    Health,
    CreateWorkspace,
}

struct Workspace {
    name: const u8[:],
}

fn routes(router: silly::Router<Route>&) {
    router.get("/healthz", Route.Health);
    router.post("/api/workspaces", Route.CreateWorkspace);
}

fn handle(ctx: Context&, route: Route) {
    match route {
        Health => {
            ctx.respond_text(200, "ok");
        },
        CreateWorkspace => {
            var scratch: u8[>..] = [];
            let input = silly::require_json<Workspace>(ctx, scratch);
            ctx.json(201, Workspace { name: input.name });
        },
    }
}

fn::main() {
    let options = silly::ServerOptions {
        address: "127.0.0.1",
        port: 8081,
        ..
    };
    let result = silly::serve<demo::Route>(options, demo::routes, demo::handle);
    if !result.ok {
        print(result.message);
        exit(1);
    }
}
```

Build and run your server from the parent workspace:

```sh
goose build demo/main.goose --offline -O2 -o /tmp/demo
/tmp/demo
```

For deeper guides, see [handlers & routing](docs/handlers.md), [streaming & files](docs/streaming.md), [client & proxy](docs/client.md), and the runnable programs in [`reference/`](reference/).
