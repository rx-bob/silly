# E3.S1–E3.S2 prepared routing, captures and method policy

`serve<R>(options, define, handle)` calls the named `define(Router<R>&)` function once,
prepares lookup data, then opens the listener. Registration failures return route IDs
before any listener is opened. The named handler receives `Context<NoState, NoStream>&`
and the selected application route value. An ordinary enum match selects application
functions; no runtime function pointer table or generated route DSL is involved.

The registration API in `reference/app.goose` is implemented. Its JSON and text helpers
remain future stories; `examples/routed.goose` is the executable version using current
response operations. It registers a static health route, scoped workspace capture and
asset catch-all. `examples/hello.goose` retains the lower-level buffered server example.

The driver owns separate growable arrays of entries, compiled segments and bytes.
`Router<R>` borrows these owners during startup. Registration copies method and path
bytes, including temporary strings; entries retain offsets, typed actions and options.
Preparation exposes const slices through `RoutePlan<R>`. Keep owners live and unchanged
through the plan's last use. There is one implementation: a bounded scan of prepared
entries and segments. Request matching does not register routes, tokenize stored pattern
strings or construct temporary route buffers. This is not a trie or a throughput claim.

Registration supports explicit get/post/put/patch/delete/head/options, arbitrary token
methods, and any fallback. `scope(prefix)` invokes its static block immediately and
restores the enclosing prefix afterward. Nested paths join at preparation time. Route
options default to buffered input; streamed input is refused until its body driver exists.

Literal segments precede captures; captures precede a final named catch-all. Exact
methods precede any fallback for the same shape. Captures remain raw bytes; `param(ctx, name)` exposes them without decoding.
Scoped method policy and explicit decoding are described below. E2.S2 now collects bounded request bodies; persistence remains E2.S4 work. The current routed server
uses the existing bounded, close-only response transport.

Preparation errors are sticky. Duplicate method/path shapes, ambiguous capture names,
repeated capture names, malformed wildcard placement and exhausted configured limits
fail before traffic. Stable registration-order route IDs index inventory and dispatch.
Inventory includes the original method/path, action, options and compiled segment data.

`route_method(plan, id)` and `route_path(plan, id)` expose copied inventory text.
`route_capture(plan, id, target, name)` returns a present/raw value for a matching route;
unknown names or nonmatching targets return absent. `param(ctx, name)` and `ctx.param(name)` return the same present/raw value
inside a routed handler. Absolute HTTP(S) targets use their raw path (empty means `/`); query text is
ignored for routing. CONNECT authority and OPTIONS asterisk are not path routes yet.
Repeated/trailing slashes are significant, and a final catch-all can capture an empty
suffix. Capture names are route-local: equivalent shapes under one method are rejected
(renamed captures report ambiguity). Distinct terminal literals can name captures
independently.

`ServerOptions.route_limits` configures finite preparation/matching budgets:

| Limit | Default | Accounting |
| --- | --- | --- |
| routes_max | 1024 | Registered entries |
| path_bytes_max | 8192 | Joined pattern or extracted request path |
| segments_max | 128 | Segments per pattern/request, including empty segments |
| captures_max | 32 | Named captures per route |
| storage_bytes_max | 1048576 | Copied methods, joined paths and scope prefixes |
| compiled_segments_max | 16384 | All retained compiled segments |
| method_bytes_max | 32 | Bytes in a registered method |

Path/method maxima must be positive; other maxima may be zero. Capacity failures return
RouteIssue rather than silently dropping routes. RouteIssue identifies the failed
registration index and conflicting prior route when applicable. `serve` exposes it in
`ServerResult.route_issue` with ServerError.Routes. Streamed options are deliberately
unsupported at this stage. Startup temporary joined-path and segment arrays are bounded
by their respective per-route limits; retained arrays have aggregate limits.

The pinned compiler requires narrow global typed bridges for external `router.get` and
`router.scope` syntax. `route_ufcs.goose` contains only these bridges; implementation and
data stay in the silly namespace. Both qualified calls and reference method syntax are
covered. No global runtime route state is introduced.

Optimized example output selects `plan.entries[selected.route_id].action` then executes
a direct C switch over the application enum. Registration calls occur in the startup
routes function. The matcher has no data-stack parameter or allocation operation;
request slices are inspected against precompiled offsets. Preparation scans prior
entries for conflicts; matching scans bounded entries/segments. This trades a simple
representation for linear route-count lookup cost, with no interchangeable engines.

The route fixture's optimized diagnostics report nine data-stack regions, with 32/50
index and 8/27 slice checks eliminated. The routed server example uses 17 regions,
including existing server buffers and per-response builders. Each region's default
2 GiB reservation is virtual address space, not resident memory. No new checkfree
annotation or unchecked indexing was introduced.

E3.S3 now supplies [endpoint guards, typed state and handler cleanup](endpoint.md).
Next in the plan: **E4.S2 — Decode path, query, and URL-encoded forms with explicit policies**.

Verification on 2026-10-27 with Goose runtime `4d3da949e563`:

- macOS arm64, Apple clang 17: four routing suites, real routed socket fixture,
  production dispatch proof, and affected legacy server/head socket regressions pass
  release/debug. Both new immutable-plan compiler negatives match their diagnostics.
- Ubuntu 24.04 x64 under Docker emulation, GCC 13.3: 25 positive executables pass in
  each mode, including routing, transport, core ownership, continuation/queue regressions
  and dispatch proof. Nine expected compiler rejections per mode match diagnostics.
  The routed example builds in both modes.
- The route inventory tests 70 representative method/path shapes covering the audited
  E1.S1 application domains. It proves framework declaration/matching coverage, not
  implementation of application business rules or a completed PromptNook port.
- Full source/reference formatting and whitespace checks pass. Documentation/reference
  directories retain their existing ignored status; no consumer repository was edited.

E2.S2 admits body collection after route selection and before handler dispatch. Optional
RouteOptions.body_bytes_max tightens the server cap; invalid negative values below -1
fail preparation. Early unmatched/unsupported requests close without draining a body.


## Scoped method policy

All three `RoutePolicy` switches default to false, preserving explicit registration and
an empty 404 for unmatched methods. Set `group.policy` inside a scope before registering
its routes. Each entry snapshots the current policy; nested scopes inherit it and restore
the parent's policy and prefix on normal return.

```goose
router.scope("/api") {
    group =>
    group.policy = silly::RoutePolicy {
        head_from_get: true,
        automatic_options: true,
        method_not_allowed: true,
    };
    group.get("/items/:id", Route.Read);
    group.patch("/items/:id", Route.Update);
};
```

Selection first searches explicit methods and `any` registrations. Within that set,
literal beats capture, capture beats final catch-all, exact termination beats an empty
catch-all, and explicit method beats `any` for the same shape. Thus an application `any`
fallback also overrides generated handling. PUT and PATCH are distinct, case-sensitive
tokens; registering both is the deliberate alias mechanism. Body collection uses the
selected route's body limits independently of its verb.

If no explicit registration matches, HEAD can select the best GET entry when that entry
has `head_from_get`. The handler still sees method HEAD and the wire writer suppresses
its body. Otherwise the best matching path entry controls generated OPTIONS (204) and
unsupported-method handling (405). Equal path specificity across different methods uses
registration order to choose the governing policy. Use consistent policy within a
resource when configuring its methods separately. Unknown paths remain 404.

Generated 204/405 responses include `Allow`: unique registered matching methods in
case-sensitive byte order, plus HEAD if the best GET permits it and OPTIONS if the best
path permits it. `route_allow(out, plan, target, cap)` exposes the same atomic, bounded
serializer; cap includes existing output. It scans prepared metadata without allocating
route buffers. It omits the empty `any` token; its finite inventory cannot enumerate all
methods accepted by `any`. Such routes never need generated 405 handling.

Generated method responses finish during head admission, before body collection or
100 Continue, including requests advertising a body above the collection limit. They
use the ordinary bounded response builder and configured precommit error renderer.
Explicit routes and application fallbacks retain ordinary body admission. All responses
currently close the connection; unread bodies are not drained.

Applications choose their own fallback envelopes with `group.any("/*rest", Route.Missing)`
and an ordinary handler response. A method-specific catch-all can limit fallback to one
verb. This also gives scoped OPTIONS/unsupported-method control without a framework JSON
envelope. The compiled prefix prevents the fallback from escaping its mount.

## Exact paths, mounts and raw captures

Scope paths begin with `/` and join the current prefix literally. Empty route pattern
registers the mount root; `/` registers its trailing slash. A domain registration function
can mount under `/api/workspaces` or `/moved` unchanged, including captured prefixes.
Repeated and trailing slashes are significant; there is no normalization, redirect,
dot-segment removal, case folding or implicit decoding. Empty request targets are invalid.
Ordinary captures require a nonempty single segment. A final `*name` consumes the raw
suffix, including repeated slashes, and can be present with an empty value. For example,
`/files/*path` matches `/files` and `/files/`; an explicit `/files` wins when both exist.
An exact share route rejects all surplus segments. Path, segment and capture limits
produce errors before dispatch, including wildcard requests; no prefix truncation occurs.

`param(ctx, name)` borrows original target bytes through a compiled capture view scoped
to the handler. An unknown name returns `present: false`; an empty catch-all returns
`present: true, value: ""`. Capture names and route metadata borrow the immutable plan.
A compiler-negative fixture verifies that target storage cannot be reset while a capture
remains in use. No route-pattern tokenization occurs in handler capture lookup.

Encoded separators remain inside a raw segment: `a%2Fb` is one capture. `a+b@example.test`
retains the plus. `decode_path(out, raw, cap)` explicitly decodes percent triplets exactly
once into caller-owned bytes; it never converts `+` to space. `%252F` becomes `%2F`, not
`/`. Malformed triplets and capacity overflow leave output unchanged. Decoding is byte
oriented (including NUL and non-UTF-8), with no filesystem or text validation implied.
Malformed percent text can match raw routes; only explicit decoding validates it.
Query extraction and form decoding remain E4.S2. CONNECT authority and OPTIONS `*`
remain outside path routing and return InvalidPath here.

E3.S2 verification: new exact-path, method-policy, capture and socket suites exercise
movable PromptNook domain patterns, raw email/key captures, slash policy, limits,
explicit overrides, deterministic Allow and early 405/OPTIONS before 100 Continue.


Validation on 2026-10-27: all 12 affected positive fixtures pass on macOS arm64 in debug
and release, including four new suites and existing routing/body/response/server
regressions. The capture-reset negative is rejected in both modes. Formatting and
whitespace checks pass. Linux execution was blocked before launch: Docker left all new
containers in Created, including a minimal network-free probe. No Linux results are
claimed for E3.S2. The full rerun script is `/tmp/silly-e3s2-linux/run.sh`; Docker cleanup
also stalled for scratch containers `330d0a07164b`, `e3e0b8cc176d`, `cd4e5ce959d2`.
