# CORS and scoped error policies

E5.S3 provides explicit startup configuration and one static error renderer. No request-time
callback chain is retained in the router. The PromptNook-compatible policy is:

```goose
router.scope("/api") {
    api =>
    api.error_policy(2);
    api.cors(silly::CorsPolicy {
        origin: "*",
        methods: "GET, POST, PUT, PATCH, DELETE, OPTIONS",
        headers: "Content-Type, Authorization",
        preflight_status: 200,
        options_without_origin: true,
        ..
    });
    api.get("/items", Route.Items);
};
```

This produces an empty 200 for valid OPTIONS requests, including the explicitly enabled
legacy form without Origin/request-method fields. It happens before body collection or
100 Continue. An unread framed body forces close; bodyless successful preflight can reuse
the connection. Preflight does not invoke the application handler.

## CORS configuration

`CorsPolicy` supports one `origin`, or a comma-separated `origins` allowlist, never both.
Origins are exact serialized HTTP(S) origins (or explicit `null`), not URL paths or patterns.
Origin matching is case-sensitive. The sole `*` origin is permitted only without credentials.
Empty origins disable framework CORS, including inherited policy in a nested scope.

`methods`, `headers` and `expose_headers` are explicit comma-separated token lists. Methods
match case-sensitively; request-header names match case-insensitively and allow HTTP list
whitespace. Header/method wildcard lists are not supported: Authorization must be named.
`credentials` defaults false, `preflight_status` defaults 204 and accepts 200–299,
`options_without_origin` defaults false, and `max_age_seconds` defaults zero (omit Max-Age).

Origins/configuration reject control bytes and header injection. Invalid startup policy,
including wildcard origin plus credentials, becomes `RouteError.InvalidPolicy` before the
listener serves requests. Oversized policy strings also reject; they are never truncated.

An unlisted Origin or requested method/header returns 403. Malformed or duplicate Origin /
preflight singleton fields return 400. Ordinary requests without Origin may continue;
dynamic policy emits no allow-origin field for them. Actual Origin-bearing methods must
also appear in the configured method list. A wildcard policy emits its static fields even
without Origin, preserving the existing PromptNook response shape.

## Header ownership and caching

For enabled CORS, the policy owns all `Access-Control-*` response headers. Before wire
staging it rebuilds bounded metadata, removes application-provided conflicts (including
credentials fields that the policy does not enable), and emits one canonical set. Unrelated
headers and the payload remain unchanged. This applies equally to success, explicit guard
rejection and fresh application/error-renderer output.

Allowed responses receive Allow-Origin, configured Allow-Methods / Allow-Headers and
Expose-Headers, plus literal `Access-Control-Allow-Credentials: true` when enabled.
Methods/headers are also emitted on ordinary responses for PromptNook compatibility.
Max-Age is emitted only for preflight. Exact-origin/allowlist policies merge `Origin` into
Vary even on denied and missing-Origin requests. Every OPTIONS response additionally varies
on Access-Control-Request-Method and Access-Control-Request-Headers, including when those
fields are absent. Existing Vary tokens are deduplicated case-insensitively; `Vary: *` wins.
These rules follow the [Fetch CORS protocol and cache guidance](https://fetch.spec.whatwg.org/#http-cors-protocol).

Metadata normalization completes before wire framing owns immutable segments. Header byte
and count limits remain enforced. If even the configured renderer/policy cannot fit or
produce a valid response, the existing final empty 500/close fallback is used; it may omit
policy fields rather than exceed limits or emit conflicting headers.

## Scope snapshots and consumer errors

`router.error_policy(nonnegative_id)` supplies application-selected renderer tags.
`router.cors(...)` and `error_policy(...)` each retain an immutable snapshot at the current
scope. Child scopes inherit current settings and restore the parent's settings on exit.
Configure a policy before declaring its routes: known routes retain that snapshot even if
later declarations change the same prefix. A nested disabled CORS policy leaves retained
application response helpers in control, useful where Portal JSON has CORS but proxy errors
intentionally omit it.

For unmatched paths, selection uses the longest configured literal prefix on a path-segment
boundary; later declarations win ties. `/api` does not match `/apix`. Query text does not
participate. Policy declarations inside capture/wildcard scope prefixes reject; captured
routes can still inherit policies from literal parent scopes. Explicit route registrations,
including catch-all handlers, retain their own policies and take precedence over implicit
not-found scope selection.

The existing static callback `render(response, failure: ResponseFailure)` handles scoped
not-found, generated method errors, body/admission errors and application failures. Switch
on `failure.error_policy`, then kind/status as needed. Configured 405 responses retain a
canonical bounded Allow field. Application-provided conflicting/duplicate Allow fields reject.
Unconfigured generated method replies preserve the prior routing behavior.

`ResponseFailure` also carries copied method (32 bytes), original target (8,192 bytes),
truncation flags and an owned `AuditRecord`. A request ID selected by earlier middleware is
therefore available when rendering a failed handler. Unmatched requests need not have run
middleware; their audit record may be empty. Values remain untrusted application input and
must be serialized/escaped for the consumer's chosen envelope.

Policy selection occurs only after strict head validation. Invalid/ambiguous heads and
failures before scope selection use tag 0, with no automatic CORS or Origin reflection.
A valid request line may still supply bounded method/target diagnostics. Body framing,
media/application and guard errors after valid-head selection retain the selected scope.
The global parser renderer can choose trusted static headers explicitly; the framework does
not infer a scope or reflect unvalidated header data.

The socket fixtures preserve distinct source-derived families: API `{"error":"Not found"}`,
global errors with path, admin structured `not_found` / `data_absence` errors and Portal
plain errors without Content-Type/CORS. Envelope contents, request-ID generation,
authentication and domain body policy remain application-owned.

## Storage and validation

Compiled policies own all startup strings: origins 2,048 bytes, methods 256, request-header
list 512 and exposed-header list 512. Each reflected origin is capped at 512 bytes. The
router owns a growable policy tail bounded by `RouteLimits.response_policies_max` (default
128); each configuration declaration consumes one snapshot. The prepared plan borrows
that table, and the compiler rejects clearing it while the plan is live. Prefix bytes use
the existing route-byte storage. Fixed per-connection CORS decisions and scoped Allow
(maximum 512 bytes) are additional bounded metadata, not unbounded request buffers.

`cors_test` covers validation, decisions, header replacement, Vary, capacities and custom
2xx status. `error_policy_test` covers scope inheritance, immutable snapshots, prefixes,
limits and policy lifetime. `cors_server_test` exercises preflight before body admission,
consumer envelopes, guard/handler failures, audit IDs, malformed-head versus scoped-body
errors and policy reset on persistent connections.
