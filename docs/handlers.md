# Handlers, routing and response ownership

Import `silly` from the checkout's package root and keep application `main` outside
the library. The three-callback families use compile-time functions, not stored
closures or request-time registration. The complete
[small application](../reference/app.goose) is the starting point;
[response helpers](../reference/responses.goose) is a runnable example of each
ordinary response form.

## Startup and route declarations

A declaration function receives `Router<Route>&`. Add methods with `get`, `post`,
`put`, `patch`, `delete`, or `add`; `any` is an explicit method-independent route.
Declarations copy path/method bytes into bounded driver-owned startup storage.
Preparation checks ambiguity, duplicate captures, limits and policies before the
listener accepts work. The prepared plan selects one typed action, then invokes
`handle(ctx, route)` through static dispatch.

Literal segments outrank named captures and catch-alls. `/:workspace_id` captures
one raw segment; `/*path` is a final catch-all. Scoped declarations join mount
prefixes on segment boundaries. Declare a fallback explicitly; the router does not
invent application JSON envelopes. Optional `RoutePolicy` enables HEAD-from-GET,
automatic OPTIONS and method-not-allowed responses. `CorsPolicy` and error policies
inherit through scopes; application authentication remains handler/middleware code.
Read [routing](routing.md) and [CORS](cors.md) for exact matching and policy rules.

`Context.param("workspace_id")` returns a presence/value pair. The value remains raw
percent-encoded path data. Do not decode it accidentally when the existing domain
module expects a raw ID. Query/body/header values also distinguish missing from
empty; their lifetime ends with the request owner unless explicitly copied.

## Typed state and endpoint boundaries

`Context<App, StreamState>` borrows request views, the response builder and the
owning application state. Small buffered applications may use `NoState` and
`NoStream`. The five-argument `serve(options, app, routes, handle, lifecycle)` shape
adds typed state/lifecycle; the six-argument streaming overload adds `step`.
Callbacks are static generic arguments even though they appear at the call site.

Owner initialization copies setup/configuration; it must not copy open process-global
native handles between threads. `Lifecycle.Start` and `Stop` belong to each owner.
`HandlerFinished` reports endpoint completion, and `TransferFinished` reports actual
transport completion/cancellation. Finishing a handler is not proof that a peer
received bytes. Completion events carry owned bounded metadata, not a mutable
response builder. See [middleware](middleware.md) for hook order and failure rules.

Terminal `reject_*` helpers leave the checked endpoint boundary, including nested
guards, and cleanup runs once outside that boundary. Ordinary response helpers only
prepare a response; return from your handler after selecting one. The pinned compiler
requires deferred generic helpers such as `fn require_auth<C>(ctx: C&)` when they call
terminal guards from static endpoint dispatch; working references demonstrate this
shape. Do not simulate an endpoint exit by returning only from an inner helper.

## Request access and application diagnostics

- `ctx.header`, `header_raw`, `header_wire` and ordered `header_values` supply trimmed,
  trailing-whitespace-preserving and wire views without conflating absent/empty.
- `ctx.body` accesses a buffered body. JSON helpers offer typed parsing, views and a
  raw reader; form/query helpers use caller-owned scratch. A streamed request body
  is consumed through stream events instead of materializing `ctx.body`.
- Keep domain JSON model rules and exact error text in application code. `json_bytes`
  sends already serialized bytes; it does not reorder keys or rewrite diagnostics.
- Explicitly use the documented query compatibility policy for legacy malformed
  escapes. Safe filesystem path decoding remains strict and is not changed by a
  query compatibility setting.

The [consumer adapters](../examples/promptnook_contract/adapters.goose) retain
status/payload and handled/status/payload returns, Admin out parameters and metadata.
Their optional [legacy snapshot](../examples/promptnook_contract/snapshot.goose)
incurs one bounded owned copy and replaces stale framing with decoded Content-Length.
It is not the original request wire. Never import legacy response wire into the
normal writer; adapt status, headers and body separately.

## Preparing and committing responses

`text`, `html`, `json`, `json_bytes`, `bytes`, `empty`, `redirect` and `attachment`
write through the same bounded response builder. HTML helpers escape text and quoted
attributes; they do not sanitize arbitrary script, event-handler or URL contexts.
Binary bytes, including NUL and non-UTF-8 data, remain opaque.

Response phases separate empty selection, building, prepared output, committed
headers and terminal completion/failure/cancellation. The normal transport owns
commitment after the endpoint returns; application handlers do not write to socket
file descriptors. Check `ResponseError` when selecting operations that may fail.
Second selections and late writes have explicit errors. The shared writer owns
Content-Length/chunked framing, HEAD/no-body rules and persistence.

Before wire commitment a selected error policy or stream failure response may still
replace output. After commitment, a failed producer closes the incomplete transfer;
it cannot append a second HTTP response or a successful chunk terminator. The
[streaming guide](streaming.md) explains pending metadata and cancellation ownership.

## Limits and native execution

`Limits` bounds retained head/header data and buffered body/output storage.
`RouteOptions.body_bytes_max` separately bounds streamed request admission/reading.
Set both deliberately in mixed applications. Runtime connection/slab budgets,
queues, stream chunks and client/file pools also reserve finite capacity.
Invalid configuration fails startup; saturation is an observable admission outcome.

`Execution.Serialized { lane: "promptnook_native" }` selects one named process-wide
lane for a complete blocking native operation. The executor owns copied request
messages and response snapshots; its request and response bodies each have a 64 KiB
hard cap, separate from the HTTP buffered-body limit. A bigger HTTP limit does not
make native work messages bigger. Retain custom application parsing inside the lane
where it touches Turso/password/ZIP state. Nonblocking unrelated routes stay inline.

The [PromptNook reference](../reference/promptnook.goose) demonstrates initialization,
registration and shutdown with inert handlers. The
[native fixture](../examples/promptnook_contract/native_state.goose) proves process-global
C-state sequencing and close-once ownership; it does not link a real database.
Multiple I/O workers do not make C statics thread-safe. Parallel native execution
requires explicit reentrant handles, genuine thread-local state or process isolation.

## Listener lifecycle and later application port

Simple `serve` owns its listener for the duration of the call. Runtime APIs also
accept caller-created listener descriptors and shutdown readers; successful ownership
transfer means the caller must not close them again. `run_runtime_listeners*` retains
listener identity on requests, including copied native messages. A shutdown deadline
may return an active `pending` handle: keep it and call `resume_shutdown` until it
finishes. Do not discard an incomplete result or kill a blocked native operation and
pretend resources were released.

The later PromptNook port retains CLI modes, configuration, migration/seeding,
credentials, domain stores/parsers and audit sinks. Register the audited route shapes,
keep native startup/operations/cleanup on their owning lane, choose explicit limits,
and wire lifecycle facts into application logs. Use the
[migration matrix](migration_notes.md) for deliberate protocol changes; no domain
port or production deployment is performed by these examples.
