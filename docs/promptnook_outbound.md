# PromptNook outbound consumer contracts

E9.S4 supplies ordinary consumer modules in `examples/promptnook_contract`. They use
public request/query/JSON APIs and the optional client/proxy package. They do not read
production configuration, query a business database, or run a curl subprocess.

Run `sh tests/promptnook_proxy_test.sh` for disposable local HTTP and HTTPS fixtures
in debug and optimized modes. The runner creates its own CA and server certificate;
certificate verification remains enabled. `tests/promptnook_audit_cases.goose` is an
additional standalone debug/optimized audit contract test.

## Portal policy

Import `portal_proxy` alongside `silly`, `client` and `proxy`. Pass `prepare(request,
Config)` an explicit bounded list of `Environment {name, base_url, token_configured,
token}`. `Prepared` owns URL, selected environment and selected authorization bytes.
Check its error, render `policy_response` through the normal server response API, or
call `start(ctx, client, prepared, inspection_bytes_max, tag)` before returning.
The reference `files_and_portal.goose` demonstrates a local-only axiom environment
and the existing static fallback. The example configuration does not consult env vars.

Source contracts were checked against
`/Users/bob/repos/nook/promptnook/backend/goose/portal/portal.goose` and `http_posix.c`:

| Source | Preserved policy | Executable coverage |
| --- | --- | --- |
| `portal.goose:118–170,214–220` | Missing selector defaults to axiom; explicit empty stays empty; unknown entries fail; uppercase names always fail. Absent token config extracts and trims exact `Bearer `; nonempty configured token overrides; empty configured token forwards incoming Authorization. Inert fallback accepts only axiom. | `promptnook_portal_cases.goose`, local proxy fixture |
| `http_posix.c:893–965,1217–1277` | Selection distinguishes raw presence from decoded first value. Forwarding removes decoded environment keys case-insensitively, splits ampersand/semicolon, groups repeated values by first key occurrence, tolerates malformed escapes and form-reencodes. Prefix and base path join; base query discarded. | Portal policy fixtures and echoed HTTP/HTTPS targets |
| `http_posix.c:1354–1370` | Incoming Host/User-Agent/Accept preserved; absent User-Agent becomes Crystal; absent Accept suppressed. Missing Accept-Encoding selects automatic gzip/deflate decoding; explicit encoding, including empty, selects raw bytes. | Local header/gzip fixtures |
| `portal.goose:282–307`, `http_posix.c:1286–1333,1392–1394` | Application JSON invalid-environment and transport envelopes; typed DNS/connect/TLS text mapping; other failures use reachability fallback. Error responses omit Content-Type as before. | Every ClientError class in Portal unit cases; real refused connection and certificate mismatch |
| `portal.goose:76–113,234–279,311–369` | Identity precedence, read/write action, response kind, lookup identifier, error code/message, mutation reason/entity, status outcome. | `promptnook_audit_cases.goose`, bounded live inspection hook |

The raw selector quirk is deliberate: `%65nvironment=dev` has decoded value `dev` but
no raw `environment` key, so the old consumer appends the default and selects
`devaxiom`. Uppercase selector keys do not select an environment but are filtered
from the forwarded query. These cases have fixtures rather than silently changed behavior.

Intentional framework differences remain explicit: `/portal-api-else` is outside the
segment mount; buffers have named caps; hop-by-hop and Connection-nominated headers
are removed comprehensively. The old re-connect-on-error probe is not repeated.
Redirects remain unfollowed and TLS remains verified, preserving the source defaults.
The complete old/new policies and later port actions are in
[migration notes](migration_notes.md).
Typed diagnostic templates use a caller-supplied safe host/port and stable representative
messages rather than reconstructing OS-specific errno text or exposing credentials.

`start` defaults to incremental forwarding with no whole-response inspection. Audit
callers may request at most 32768 bytes of inspection and correlate its tag with retained
request facts. `audit_request` retains identity/environment/path and only caller-approved
lookup keys (16 allowed keys and values maximum, 1024 bytes each); it never retains Authorization or a raw
request body. Mutation extraction consumes at most 4096 bytes. `audit_response` accepts
the public inspection info/body and extracts selected JSON strings with last-key semantics.
Oversized fields and JSON parser limits set `limited`; invalid/non-JSON bodies retain
the status/path fallback. Audit query lookup splits ampersands only, as its source does,
and always excludes environment selectors.
`audit_outcome` returns denied, failure or success. Applications supply timestamps and
completion sinks; these helpers emit no logs. Choose safe lookup keys and apply the
application's data-redaction policy to free-text audit fields.

## MCP checks

Import `mcp_client`, `client` and `silly`. `normalize_url` trims outer ASCII whitespace,
normalizes scheme/host, removes userinfo/fragment, inserts a root slash and retains query
values. `begin_check` applies that normalization and admits a GET with the source Accept
value and optional Bearer token. It retains no token after admission. Call `poll_check`
on readiness until complete; each call drains/discards at most 4096 response bytes.
`finish_check` abandons incomplete work. `client_options` supplies bounded source-derived
connect/overall/idle deadlines; the application owns the client lifetime and CA policy.

`Check` exposes typed transport error, upstream status, final reason detail and byte count.
`render_check` maps 2xx to a 200 success message, 401/403 to authentication failure, other
statuses to status/reason detail, and transport errors to the original family of messages.
`poll_check_with`/`fail_check_with` allow static application error-detail hooks. All typed
client errors are covered; real HTTP/HTTPS, auth, custom reason, connect and TLS failures
exercise the ordinary client. No MCP business records or domain protocol implementation
are included. Sources: `integration_routes.goose:137–172,289–323` and
`http_posix.c:209–300`.

## Requirement coverage and build boundary

R12 outbound checks map to MCP tests; R15 proxy selection/audit maps to Portal and audit
tests; H17 path/query/auth/headers maps to Portal socket fixtures plus E9.S3 streaming
backpressure/cancellation tests; H18 URL/TLS/compression/error mapping maps to both example
families. Broader business-route coverage remains E10.S1.

The compiler currently merges nested package build ownership when core and client are
imported together. Composed executables explicitly list `client/native/client.c` and
`curl`, `z` in their own `.build` manifest, as the test and reference do. Core-only
applications still do not link those dependencies. Fresh per-mode native caches are used
by the test runner because the compiler otherwise reuses C objects across build modes.
