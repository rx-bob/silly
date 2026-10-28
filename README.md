# Silly

Silly is a Goose HTTP library for Linux and macOS. It provides HTTP/1.0 and HTTP/1.1
servers, prepared typed routing, bounded request/response helpers, owned streams,
rooted file serving, and an optional HTTP/HTTPS client and proxy package.
Applications own `main`, configuration, domain behavior and startup/shutdown policy.
Incoming TLS is terminated outside this library.

## Build and try the examples

The tested compiler installation is Goose **v2026.3**; `goose version` reports runtime
**4d3da949e563**. Use a C compiler and the platform threading/socket libraries.
Core-only programs need no database, password, outbound TLS or zlib dependency.
The optional client needs libcurl and zlib headers/libraries with HTTP/HTTPS support.
The macOS validation environment has libcurl 8.7.1 and zlib 1.2.12; these are tested
versions, not invented minimum requirements. Local HTTPS fixtures also need Python 3
and the `openssl` executable. Formatting uses Pretty Goose's current `goosefmt` and
this repository's `.goosefmt.toml` / `.goosefmt.ffi.toml`.

From this repository:

```sh
goose build reference/app.goose --offline -O0 --debug -o /tmp/silly-app
goose build reference/app.goose --offline -O2 -o /tmp/silly-app-opt
/tmp/silly-app
```

The example listens on loopback port 8081 and serves `/healthz` and JSON workspace
creation fixtures. Other reference executables use explicit loopback ports; build
commands do not launch them. `reference/promptnook.goose` chooses an ephemeral port
and supports graceful SIGINT/SIGTERM shutdown. None is a production PromptNook port.

| Reference | Public API illustrated |
| --- | --- |
| [app.goose](reference/app.goose) | Minimal typed routes, JSON input/output and terminal validation |
| [responses.goose](reference/responses.goose) | HTML escaping, form input, redirects, opaque JSON, attachment bytes and guards |
| [promptnook.goose](reference/promptnook.goose) | Inert source-audited routes, owner startup/stop and serialized native lane shape |
| [files_and_portal.goose](reference/files_and_portal.goose) | Rooted files/ranges/gzip and optional upstream proxy in one typed stream server |
| [request_stream.goose](reference/request_stream.goose) | Incremental upload/download with owned state and bounded chunks |
| [streaming.goose](reference/streaming.goose) | Runnable SSE example using [events_routes.goose](examples/events_routes.goose) |
| [dispatch_proof.goose](reference/dispatch_proof.goose) | Narrow compiler/static-dispatch proof, **not** a server implementation |

The Portal reference needs a caller-created `./public` directory and explicitly
uses a loopback upstream at port 8083. Tests create disposable roots/upstreams and
never read configured PromptNook environments.

## Import from another application

Keep this checkout beside the consumer, for example `/workspace/silly` and
`/workspace/demo`. No package publication or release tag is required. Create
`demo/main.goose`:

```goose
namespace demo;

import silly from "../silly";

import std;

enum Route {
    Health
}

fn routes(router: silly::Router<Route>&) {
    router.get("/healthz", Route.Health);
}

fn handle(ctx: silly::Context<silly::NoState, silly::NoStream> & , route: Route) {
    ctx.text(200, "ok");
}

fn::main() {
    let result = silly::serve<demo::Route>(silly::ServerOptions {
            address: "127.0.0.1",
            port: 8081,
            ..
        }, demo::routes, demo::handle);
    if !result.ok {
        print(result.message);
        exit(1);
    }
}
```

Build from the common parent directory:

```sh
goose build demo/main.goose --offline -O0 --debug -o /tmp/demo
goose build demo/main.goose --offline -O2 -o /tmp/demo-opt
```

For a complete external client/proxy example, copy
`silly/reference/files_and_portal.goose` to `demo/portal.goose`. Change its import
paths from `".."` to `"../silly"`, `"../client"` to `"../silly/client"`, and
`"../examples/promptnook_contract"` to `"../silly/examples/promptnook_contract"`.
Keep both explicit client modules:

```goose
import client from "../silly/client";
import portal_proxy from "../silly/examples/promptnook_contract";
import proxy from "../silly/client";
import silly from "../silly";
```

Create `demo/portal.build`:

```text
c_sources = ["../silly/client/native/client.c"];
c_libs = ["curl", "z"];
```

Then build with `goose build demo/portal.goose --offline -O2 -o /tmp/demo-portal`.
The current compiler merges nested core/client build ownership in composed
executables, so the consumer sidecar explicitly includes the client translation
unit and libraries. Core imports still compile their native transport/file/control
sources through `silly.build` and do not gain client dependencies. Use separate
`GOOSE_HOME` native caches when comparing debug and optimized client builds: the
current compiler otherwise reuses native objects across optimization modes.

## Contracts and verification

Read [handlers](docs/handlers.md) for routing, state, validation and response
commitment, and [streaming](docs/streaming.md) for owned streams, files, proxy and
cancellation. Detailed contracts cover [routing](docs/routing.md),
[HTTP/request ownership](docs/architecture.md), [middleware](docs/middleware.md),
[files](docs/files.md), [client](docs/client.md), and
[source-audited consumer coverage](docs/promptnook_requirements.md).

Historical story labels and early design notes remain in the plan; its ten inline
Goose reference blocks have been reconciled byte-for-byte with the current reference
files. The shipped guides and executable sources describe implemented APIs.

The deterministic Goose runner is [scripts/check.goose](scripts/check.goose);
[tests/all.goose](tests/all.goose) is its suite entry point. Build and run from the repository root (replace the formatter path with your checkout):

```sh
goose build scripts/check.goose --offline -O2 -o /tmp/silly-check
/tmp/silly-check --help
/tmp/silly-check --root "$PWD" --formatter /path/to/pretty-goose/goosefmt --mode both --group all --output /tmp/silly-results
```

`--group` accepts `all`, `functional`, `compiler`, `style`, `references`, or
`external`; `--mode` accepts `both`, `debug`, or `optimized`. `--goose` and `--python`
select tool executables; environment defaults are `GOOSE`, `GOOSEFMT`, and `PYTHON`.
`--root` and `--output` must be absolute; external consumer checks require output
outside the checkout. Run functional suites as an unprivileged user: permission fixtures
intentionally deny file access, which root can bypass. In Docker select a normal UID
with `--user`; do not skip or relax those assertions to accommodate root.
Every check writes a separate log and the runner exits nonzero on failure. Child
commands receive literal argv (no shell interpolation) and a five-minute deadline. Log inspection reads at most 16 MiB for compiler checks (larger logs
fail that check) or the final 4 KiB for failure reports. Compiler artifacts and retained
log files have no runner-imposed size limit; timed-out/cancelled process groups are stopped and reaped. Python fixture runners use
`-I` so user site packages and Python environment overrides cannot disable assertions
or change fixture imports. `tests/all.goose` exposes the same suite interface.

Checks build debug and optimized executables, validate formatter/style and negative
lifetime cases, audit targeted stack/BCE generated-code evidence, compile all references
and external consumers, and exercise real loopback transport without production services. Passing examples is not a claim
that the current PromptNook application has been ported. Platform-specific results
and compiler/native requirements are recorded with the runner evidence.

## Verification results

Debug and optimized verification passes on macOS arm64 and Ubuntu 24.04 x86_64
(the Linux container runs under Docker Desktop emulation on the arm64 host).
Functional tests run unprivileged. Both use Goose v2026.3/runtime `4d3da949e563`.

| Group | macOS | Linux |
| --- | --- | --- |
| Functional | 127 executables in both modes pass | 127 executables in both modes pass |
| Compiler/lifetime/stack/BCE | 133 checks pass | 133 checks pass |
| References and external consumers | 31 checks pass | 31 checks pass |
| HTTP/HTTPS/native external fixtures | 27 checks pass | 27 checks pass |
| Formatting | 7 checks pass | 7 checks pass |

See [verification evidence](docs/promptnook_requirements.md#final-grouped-verification-results)
for toolchain versions, count meanings and grouped-run details. These are functional
and compiler results, not a benchmark or a claim of PromptNook business parity.

## Later PromptNook port

Retain PromptNook's domain modules, database/bcrypt/ZIP implementations, credentials,
environment selection, migrations, seeds and CLI modes. Adapt status/payload and
raw-request callers at the application boundary; put complete process-global native
sequences on one serialized lane; choose explicit body/queue/deadline budgets and
wire completion facts to application logs. The detailed
[migration matrix](docs/migration_notes.md) names each entry point, deliberate
protocol correction and required port action. This repository performs no business
port, deployment, package publication or production migration.
