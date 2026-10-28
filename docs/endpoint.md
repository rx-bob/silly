# Endpoint guards and typed application state

`serve<R,A>(options, app, define, handle)` borrows caller-owned `A` for the current
single execution owner. `define(Router<R>&, A&)` runs once before listening;
`handle(Context<A,NoStream>&, R)` sees the same mutable state across requests. The
application owns configuration, session/permission policy and native-resource lifetime.
No application state is copied into global storage or hidden behind dynamic dispatch.
Future multiple-owner initialization and lifecycle APIs remain E6 work.

`serve_with_cleanup<R,A>(options, app, define, handle, cleanup)` adds a statically bound
`cleanup(A&, HandlerOutcome)` callback. The matching prepared-server APIs accept `plan`
instead of `define`; `run_prepared_server` additionally consumes caller-created listener
and wake descriptors. `_with_errors` variants accept the existing static response error
renderer, and `_with_cleanup_and_errors` variants accept both callbacks. Existing
no-state APIs now enter the same endpoint boundary.

## Guard boundary and response helpers

`endpoint(ctx, route, handle)` is the named nonlocal-return boundary.
`coordinate_endpoint(ctx, route, handle, cleanup)` invokes it, classifies the response,
and calls cleanup exactly once after normal return or a terminal guard. Applications
normally use server dispatch, which supplies this coordinator automatically.

```goose
fn require_database(ctx: Context&) {
    if !ctx.app.ready {
        ctx.reject_text(503, "Database unavailable");
    }
}

fn require_session(ctx: Context&) {
    require_database(ctx);
    if !ctx.app.authenticated {
        ctx.reject_text(401, "Session required");
    }
}
```

The rejection exits the enclosing `silly::endpoint`, including nested ordinary helper
calls. Statements after the failing guard do not run. The compiler rejects calls when
that endpoint is absent from the static call path, including calls from cleanup.
An application can also use `return from silly::endpoint;` in its own guard.

`reject_text(ctx, status, payload)` prepares text/plain with UTF-8 charset;
`reject_empty(ctx, status)` prepares an empty response. Both exit the endpoint even if
preparation fails. `reject(ctx)` exits with the application's prepared response, preserving
its exact headers/body/status, or preserves an existing failed/cancelled outcome. Calling
it with an unprepared response classifies InvalidState rather than fabricating success.
No JSON envelope, authentication scheme, DB policy or HTTP status is selected by Silly.

`respond_text` and `respond_empty` are ordinary local helpers returning `ResponseError`.
They are legal outside the boundary and do not implicitly return from their caller.
They mark duplicate starts and preparation failures on the response, so ignoring their
error cannot silently retain a successful first response. Low-level checked response
operations remain available for custom envelopes. Method-style calls have typed bridges.
Text output is copied into the existing bounded builder; all helpers remain precommit.
The existing server error renderer discards failed builders after handler borrows end.

## Cleanup, scope and cancellation

Dispatch creates a lexical child context with the selected route's compiled capture
view. It never overwrites the parent's capture view, so success, rejection and cancellation
leave parent route state unchanged. Nested mounts are already compiled into the plan.
Cleanup receives only the borrowed application state and a value `HandlerOutcome`, not
a retained request context. It runs outside the endpoint boundary; it cannot reject the
finished handler or skip outer coordination through an endpoint guard.

Prepared responses, including explicit empty 204 and application 4xx/5xx rejections,
yield `HandlerOutcome.Prepared`. Returning without a prepared response yields
`MissingResponse`. Failed or cancelled builders yield `Failed { error }`. The cleanup
callback precedes error rendering, serialization and transport; these outcomes describe
handler execution, not successful delivery. Built-in 404/405/OPTIONS and parser/admission
failures do not invoke handler cleanup because no application handler ran. A scoped
application `any` fallback does run through the boundary and receives cleanup.

This is synchronous handler completion. Socket cancellation after a completed handler
does not run its cleanup again. Transfer completion, async cancellation, full lifecycle
Start/Stop, cleanup-failure policy and middleware completion metadata remain later stories.

## Verification

`endpoint_test` covers nested 401/403/503 guards, custom envelopes, empty success,
missing responses, duplicate starts, failed preparation, cancellation and local helpers.
`endpoint_route_test` verifies parent capture restoration and once-only cleanup across
success/rejection/cancellation/scoped fallback. `endpoint_server_test` exercises typed
persistent state and guards through real sockets and the precommit error renderer.
`typed_state_test` instantiates typed serve/prepared/run wrappers and verifies startup
validation before listening and typed state access during route definition.
Negative compiler fixtures reject direct terminal helpers and nested application guards
outside the named boundary.

Next story: **E4.S2 — Decode path, query, and URL-encoded forms with explicit policies**.


Validation: endpoint unit, route-restoration and typed-state socket fixtures pass macOS
arm64 debug/release. Existing routing, body, response, context and static API regressions
pass both modes. Direct-helper and nested-guard compiler negatives fail with the expected
`no enclosing call of silly::endpoint on this compile-time call path` diagnostic.
Linux remains unverified: a fresh Docker probe stalled before launch; its unused scratch
container was removed. Rerun script: `/tmp/silly-e3s3-linux/run.sh`.
