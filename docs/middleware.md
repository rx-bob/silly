# Static middleware and lifecycle

E5.S2 adds the production buffered call shape:

```goose
silly::serve<Route, App>(options, app, routes, handle, lifecycle);
```

`routes(router, app)`, `handle(ctx, route)` and
`lifecycle(app, event: silly::Lifecycle<Route>) -> silly::HookResult` are compile-time
callbacks. No runtime closure or callback array is stored. Existing serve/cleanup/error
APIs remain available. `serve_with_lifecycle_and_errors` additionally accepts the existing
static error renderer. Prepared-plan and supplied-listener variants are named
`serve_prepared_with_lifecycle` and `run_prepared_server_with_lifecycle`; their
`_and_errors` forms accept a renderer too.

## Before and completion order

Inside the handler, compose a fixed chain:

```goose
silly::middleware(ctx, route, global_before, group_before, route_before, actual_handler);
```

Each callback takes `(ctx, route)`. Group and route selection stays in ordinary typed
route dispatch: pass the appropriate static functions for the route family mounted by
`router.scope`. The router stores no middleware closures and performs no runtime prefix
search for middleware. The PromptNook reference shows its mounted `/api` chain.

The chain enters global, group, route, then handler. An entered bit is recorded **before**
calling each guard, so a rejecting layer still gets its completion. One endpoint boundary
surrounds the entire chain. Rejection stops all subsequent guards/handler statements;
there are no nested catches that could resume an outer handler. A second/nested call to
`middleware` in the same request rejects instead of replacing the entered-layer record.

For HandlerFinished and TransferFinished events, the lifecycle callback can call:

```goose
return silly::middleware_complete(app, event, global_finished, group_finished, route_finished);
```

Completion callbacks take `(app, event) -> HookResult` and unwind only entered layers,
in route → group → global order. They run outside the guard boundary and receive no
response builder, so guard exits cannot skip cleanup and completion cannot prepare a
second response. Every entered completion runs even if an inner completion reports a
failure; the first failure is retained. Application policy and error envelopes remain in
ordinary code: a plain MCP auth rejection and an admin JSON rejection can share a router.

## Owner and event contract

The current buffered server has one owner, `Owner { id: 0 }`, borrowing `App` for the run.
`owner.is_serialized(name)` returns false: execution lanes are not implemented by this
story. Start runs once before accept/dispatch. Stop runs once after all pending transfer
cancellations, including after a failed Start so partially initialized state can be cleaned
up. Invalid options or route declarations fail before either event.

HandlerFinished runs once for an executed matched handler, after its endpoint/guard
boundary returns and before response owners expire. Its status and `handler_outcome`
describe that builder. TransferFinished runs once after final bytes have been accepted by
the socket transport, or after cancellation from a fatal read/write, output timeout or
server shutdown. Delivered is a local transport result, not remote application receipt.
The terminal pending flag is cleared before invoking user hooks, preventing duplicate
completion during subsequent shutdown or connection reset.

Input parse/admission failures may produce TransferFinished without HandlerFinished.
`handler_ran` distinguishes these from an actual handler that omitted a response. Matched
route metadata is available after valid-head admission even when a body later fails;
malformed/unclassified requests use an unavailable route. Generated method replies and
route misses have explicit classifications.

HookResult is `Ok` or `Failed { message: u8[..128] }`. Any failure stops the single owner;
remaining pending transfers are cancelled and Stop still runs. The first hook failure is
returned as `ServerError.Hook` with owned `ServerResult.hook_failure`. Handler hook failure
leaves output uncommitted; no replacement error envelope is fabricated for hook failures.
Transfer/Stop failures likewise never attempt a second response. Custom application error
renderers continue to handle ordinary response/parser failures through the existing API.

## Completion ownership and audit

`Completion<R>` contains `route: CompletionRoute<R>` and `data: CompletionData`.
CompletionRoute is Application `{ route: R }`, Generated, NotFound or Unavailable.
The connection stores only a stable route index; the lifecycle adapter reconstructs `R`
from the retained immutable route plan. Fixed completion bytes can be copied into bounded
application-owned history after the handler frame has ended.

CompletionData includes bounded method (32 bytes), target (256 bytes) and explicit
truncation flags, final/current status, handler outcome, transfer outcome, actual wire byte
count, transport system error and entered middleware bits. HandlerFinished precedes error
rendering; TransferFinished status reflects the final rendered/fallback response. Wire
bytes include informational responses such as 100 Continue and any partial final writes.

Audit is opt-in:

- `audit_request_id(ctx, bytes)` copies up to 128 bytes for correlation.
- `audit_data(ctx, bytes)` copies up to 512 bytes of application-selected metadata.
- `audit_request_payload(ctx, cap)` copies a prefix from an already buffered request.
- `audit_response_payload(ctx, cap)` copies a prefix of currently buffered response bytes.

Payload caps must be 0–256. Larger payloads are truncated with explicit flags; invalid
caps reject. Overlong IDs/data reject through the guard. Copies replace earlier selections.
No header or entire body is automatically captured. Applications choose selected headers,
request IDs and audit meaning; the framework adds no logging system. A payload snapshot
reflects the moment it was requested, so a later error renderer can produce different
wire bytes. Streamed request capture rejects unavailable input; response capture never
pulls stream data or grows a stream buffer.

The fixed Connection/CompletionData storage is bounded by `connections_max`; it is in
addition to the byte slabs covered by `buffer_bytes_max`. Every snapshot has inline
capacity, independent of stream length. Production stream scheduling remains E7; the
middleware unit fixture proves bounded audit with the existing stream-state contract.

## Checks

`middleware_test` covers entry/unwind order, nested guard exits, typed state, audit limits
and stream bounds. `lifecycle_server_test` covers plain/JSON envelopes, request IDs,
actual delivery, peer reset, timeout, shutdown cancellation, immutable snapshots and each
hook failure phase. `lifecycle_api_test` compiles the five-argument production serve shape.
