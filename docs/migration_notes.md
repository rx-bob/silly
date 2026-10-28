# PromptNook integration and later port boundaries

Silly's consumer fixtures establish framework behavior through public APIs. They
are not a replacement PromptNook backend and do not establish business parity.
The application still owns its domain modules, database, bcrypt, ZIP construction,
identity providers, environment configuration, startup seeding and migrations.
No PromptNook checkout, configured upstream or live database is changed by this work.

## Evidence and comparison rules

The source baseline and hashes are recorded in
[promptnook_requirements.md](promptnook_requirements.md) and its source manifest.
Old behavior below refers to the audited Goose backend, principally
`backend/goose/http_posix.c`, `server/*routes.goose`, `portal/portal.goose`,
`core/http.goose` and `turso/turso.c`, under `/Users/bob/repos/nook/promptnook`.

The existing `backend/migration/PARITY.md` is supporting historical evidence:
its runtime-surface rows record raw HTTP comparisons for CORS/auth, chunked and
200 KB bodies, 100-continue, keep-alive, static files, compression, ranges, and
proxy errors. It also records source-compatible signed Content-Length and HEAD
range bodies. Those two behaviors are deliberately corrected here. The historical
product gate excludes Admin, Portal, MCP, Ideas and Flagged; that exclusion does
not narrow Silly's current source-derived scope. No new Crystal/backend parity run
is claimed. The executable fixtures compare the audited framework contracts using
inert application results, not invented business success data.

Tests compare status, exact relevant header values, decoded body bytes, captures,
query values, error payloads and lifecycle outcomes. Do not normalize arbitrary
JSON whitespace, key order, raw IDs, empty headers, error text or status codes.
Generated request IDs, filesystem-derived dates/validators and multipart boundaries
may be captured from one response and used to assert a consistent relation in the
next assertion. Deterministic fixtures use fixed IDs/dates wherever possible.
Multipart tests extract the actual boundary and assert every delimiter and byte;
they do not discard multipart content. Content-Length/chunked changes below are
explicit framing policies, not comparison normalization.

## Deliberate protocol and resource changes

Every row names the later application action. Tests named here are targeted
component contracts; integrated evidence is listed separately in the requirements
ledger. A changed business envelope or omitted domain handler is not excused by
this table.

| Contract | Audited old behavior | Silly behavior and reason | Test evidence | Later port action |
| --- | --- | --- | --- | --- |
| Content-Length numbers | `pn_request_content_length` accepts a leading `+`, broad C whitespace and byte-identical duplicate values. | Digits with HTTP optional whitespace only; reject signs, overflow and conflicting lengths. Equal numeric repeated/comma-list values such as `01, 1` are accepted. One unambiguous framing decision avoids inconsistent readers. | [valid head cases](../tests/http_head_test.goose), [invalid lengths and CL/TE](../tests/http_head_invalid_test.goose) | Remove signed/invalid producers; do not reintroduce permissive numeric parsing in an adapter. Keep CL/TE ambiguity rejection. |
| Request grammar and singleton headers | Native reader primarily bounds/framing-checks input; native accessors use the first matching header and do not centrally reject repeated Authorization/Content-Type or validate HTTP/1.1 Host authority. | Validate request line, target, field syntax and Host; reject folded/control-byte input and ambiguous singleton headers instead of selecting an arbitrary credential/content type. Unsupported protocol versions have typed errors. | [grammar and singletons](../tests/http_head_invalid_test.goose), [Host syntax](../tests/http_host_test.goose), [error policies](../tests/error_policy_test.goose) | Send one valid Host/Authorization/Content-Type as applicable. Keep the application error renderer for required envelopes, but never weaken framing/credential ambiguity checks to reproduce permissive input. |
| Exact route termination | Some native segment predicates accept extra segments; Portal checks `starts_with("/portal-api")`; static method matching is case-insensitive. | Exact segment arity, case-sensitive method tokens and `/portal-api` segment mount; explicit scoped/global catch-alls supply application 404 policy. This prevents an unrelated prefix or extra path from selecting an endpoint. | [all audited routes and negatives](../tests/promptnook_routes_test.goose), [Portal policy](../tests/promptnook_portal_cases.goose) | Register all observed aliases explicitly; retain scoped auth before fallback. Do not treat `/portal-apiary` as proxy traffic. |
| Static HEAD | `pn_portal_static` detects HEAD but appends file, range and directory bytes anyway. Historical parity evidence intentionally matched that body. | Suppress body bytes for HEAD and ignore Range/If-Range on HEAD: return full selected representation metadata (or conditional 304), not a partial 206 body. Shared writer also enforces no-body status rules. | [response wire rules](../tests/http_response_test.goose), [static metadata](../tests/static_metadata_test.goose), [range sockets](../tests/file_ranges_socket_test.goose), [Portal static](../tests/static_portal_test.goose) | Update clients/fixtures that incorrectly consume HEAD bodies; do not restore the bug for byte parity. |
| Multipart ranges | Source emits `multipart/byterange`, whole-body chunk framing, part Content-Length and a closing boundary without final CRLF. Compressed ranges put Content-Encoding on the outer multipart response. | Valid `multipart/byteranges`, deterministic exact aggregate length, correct CRLF boundaries; compressed representation coding belongs to each part, not the multipart container. | [multipart bytes](../tests/file_multipart_test.goose), [compressed multipart](../tests/static_portal_cases.goose), [range sockets](../tests/file_ranges_socket_test.goose) | Compare parsed boundary-consistent multipart bytes and explicit new framing; keep the corrected plural media type. |
| Range parsing and limits | Source supports up to 64 ranges, returns 400 for malformed syntax and 416 for unsupported units; an unsatisfiable member can fail the whole set; some empty-file suffix ranges return 200. | At most 16 ranges and 4096 field bytes. Malformed/unsupported/over-cap fields are ignored for full 200; valid unsatisfiable sets return 416, satisfiable members survive mixed sets, and all empty-file ranges are unsatisfiable. Range unit comparison is case-insensitive. This applies a bounded, consistent range policy. | [range grammar and caps](../tests/file_ranges_test.goose), [range wire policy](../tests/file_ranges_socket_test.goose) | Update exact status expectations; choose a smaller cap if needed, never bypass the hard bound. |
| If-Range | Source static handler does not consult If-Range. | Strong entity tags or explicitly allowed strong-date policy gate ranges; mismatch/weak tags yield the full representation. | [If-Range cases](../tests/file_ranges_test.goose), [selected gzip representation](../tests/static_portal_cases.goose) | Keep validator strength explicit and do not serve partial bytes after a failed validator. |
| Static validators and dates | Source uses original-file second-resolution `W/"mtime"` and Last-Modified even for gzip; If-None-Match uses string equality; If-Modified-Since allows one extra second. | Descriptor-derived selected-representation metadata; default weak ETag includes stat identity/size/nanoseconds. Weak comparison and full-list validation for If-None-Match; HTTP date comparison has no extra second allowance. A supplied validator remains an application policy. | [conditions](../tests/file_conditions_test.goose), [metadata](../tests/static_metadata_test.goose), [gzip validators](../tests/static_portal_cases.goose) | Expect cache revalidation after port; keep distinct encoded bytes' strong validators distinct. Preserve exact custom tags only with a correct selected-representation callback. |
| Gzip selection | Source recognizes a case-insensitive gzip substring with non-alphanumeric boundaries, without quality negotiation; no Vary header. | Case-insensitive coding, q-values, wildcard/identity exclusions; q=0 never selects gzip, unavailable acceptable encoding yields 406, and responses vary on Accept-Encoding. The example preserves the source's strictly-less-than-10-ms gzip freshness tolerance. | [encoding parser](../tests/accept_encoding_test.goose), [Portal encodings/freshness](../tests/static_portal_cases.goose) | Configure the 10-ms tolerance explicitly; update q=0/406/cache expectations. Do not silently reuse an identity cache entry for gzip. |
| Rooted files and symlinks | Source passes raw percent-escaped paths to the filesystem, resolves realpaths then opens, allows links whose resolved path remains inside root, and lists directory entries in filesystem order including nonregular/link names. | Descriptor-relative rooted opens decode URL paths exactly once, then reject symlinks, traversal, malformed escapes and encoded separators; listing includes regular files/directories only and sorts bytewise. Bounded work and pinned descriptors remove check/open races. | [root containment and replacement](../tests/files_test.goose), [Portal listings](../tests/static_portal_cases.goose), [HTML/listing bounds](../tests/directory_html_test.goose) | Replace symlink-based asset layouts with real files under the configured root; percent-encode literal percent names and update ordering expectations. Retain explicit root-listing fallback instead of assuming implicit SPA/index behavior. |
| Whole-request and output growth | Source reader grows past its initial 128 KiB buffer; static/proxy capture and response builders grow with payload size; write helpers return no progress/error outcome. | Named admission and byte caps; incremental file/proxy/stream transfer, backpressure, explicit cancellation and incomplete-write outcomes. Large buffered bodies are supported within configured limits, not an accidental 128 KiB ceiling. | [large/chunked bodies](../tests/http_body_server_test.goose), [body limits](../tests/http_body_limits_test.goose), [file cleanup](../tests/file_transfer_test.goose), [proxy streaming](../tests/proxy_test.goose) | Set finite production budgets deliberately; stream large transfers and check return values. A disconnect must release ownership, not produce a second success response. |
| Persistence and framing | API native writer appends `Connection: keep-alive`; Portal handles one request then closes. Many helpers return complete HTTP wire bytes. | Shared writer chooses HTTP/1.0/1.1 framing, HEAD/no-body semantics and connection lifetime; HTTP/1.1 persistence need not emit an explicit keep-alive field. Ordered pipelining retains unread bytes. | [connection persistence](../tests/http_connection_test.goose), [wire writer](../tests/http_wire_test.goose), [legacy adapters](../tests/promptnook_adapters_test.goose) | Adapt status/headers/body at the caller boundary. Never import arbitrary legacy response wire into the normal writer. Assert explicit header values where semantic; accept the documented connection/framing choice. |
| Proxy hop headers | Source filters a small fixed list and does not remove all headers nominated by Connection. | Remove standard hop-by-hop fields and Connection-nominated fields in both directions; framing is rebuilt for the destination connection. | [proxy header rules](../tests/proxy_headers_test.goose), [proxy sockets](../tests/proxy_test.goose) | Do not rely on forwarding connection-local fields. Preserve application end-to-end headers through the supplied policies. |
| Portal deadlines | Source Portal curl child has no overall/connect/read deadline, matching its recorded Crystal default. | Default client uses queue 30 s, connect 10 s, first-byte 30 s and idle 30 s; total timeout defaults to 0. Limits and cancellation keep abandoned work bounded. MCP example retains its own source-derived shorter deadlines. | [client transport](../tests/client_transport_test.goose), [client HTTP deadlines](../tests/client_http_test.goose), [proxy cancellation](../tests/proxy_test.goose) | Choose finite deadlines for deployed upstreams and map timeout errors through the consumer policy. No claim that a request longer than the old 60 s historical deadline was compared. |
| Portal transport error detail | Source performs another DNS/connect probe after curl failure and may expose host/OS-specific errno text. | Typed error categories select stable source-family templates from caller-supplied safe host/port; no repeat connection probe. Other failures use the documented reachability message. This bounds work and avoids unstable diagnostic reconstruction. | [all typed mappings](../tests/promptnook_portal_cases.goose), [local refusal/TLS](../tests/promptnook_proxy_test.goose) | Retain envelopes/status, approve stable message templates, and supply safe destination display data. Do not normalize arbitrary error text as if exact parity had been proven. |
| Proxy audit retention | Source can parse/log a fully buffered response and request. | Streaming defaults to no full inspection; optional inspection is capped at 32768 bytes. Retain only approved lookup fields, bounded mutation facts and status fallback; `limited` records cap/parser limitations. | [audit values and limits](../tests/promptnook_audit_cases.goose), [live inspection](../tests/promptnook_proxy_test.goose) | Choose approved lookup keys, redact free text, and handle limited/status-only audit facts. Timestamps and audit persistence stay application-owned. |
| Native global state | Turso database/statement/rows and ZIP assembly are process globals; old accept loops serialize calls implicitly. | Complete native sequences execute on one named process-wide serialized lane. Queue messages own copies and stale generations cannot apply results to reused connections. Other I/O owners remain serviceable. | [native detector and sequences](../tests/native_state_test.goose), [lane admission](../tests/serialized_lane_test.goose), [stale completions](../tests/queue_routing_test.goose) | Open/close native state only on its owning lane; never call those globals directly from I/O workers. Reentrancy, explicit handles or process isolation is required before parallel native execution. |
| Shutdown and blocking work | Source blocking accept/read/write/native calls have no resumable owned shutdown result. | Stop admission, cancel I/O/work, preserve resource ownership until cooperative jobs finish; incomplete shutdown returns a retained handle to resume. | [shutdown resume](../tests/shutdown_resume_test.goose), [native active shutdown](../tests/native_state_test.goose), [two listeners](../tests/shutdown_listeners_test.goose) | Retain and resume an incomplete result. Do not drop live handles or assume cancellation can kill a blocking C call. |

## Compatibility retained at application boundaries

These are **not** accidental deltas and must not be erased during the later port:

- Missing versus empty header/query values remain distinct. Header lookup offers
  wire, raw trailing-whitespace-preserving and trimmed views; raw captured IDs
  remain percent-encoded. The [header](../tests/header_auth_test.goose),
  [query](../tests/query_compat_test.goose) and [adapter](../tests/promptnook_adapters_test.goose)
  contracts cover them.
- Portal selector presence, decoded lookup and forwarding intentionally retain the
  source quirks: `%65nvironment=dev` can select `devaxiom`; forwarding removes decoded
  environment keys case-insensitively and groups repeated values by first key.
  Missing token configuration extracts an exact Bearer prefix; an explicitly empty
  configured token forwards incoming Authorization; nonempty configuration overrides.
  Incoming Host/User-Agent/Accept and explicit empty Accept are retained; absent
  User-Agent becomes Crystal and absent Accept stays absent.
- Missing Accept-Encoding performs implicit gzip/deflate decoding. Explicit
  Accept-Encoding, including empty, requests raw response bytes. Redirects are not
  automatically followed and TLS verification remains enabled: these are preserved
  source defaults, not newly introduced differences. See the exact
  [outbound source/test mapping](promptnook_outbound.md).
- Domain JSON readers/writers, missing/null/duplicate semantics and diagnostic
  locations remain application code. `Context.body` and response bytes do not
  rewrite those payloads. MCP's two plain auth errors omit Content-Type; ordinary
  JSON payloads keep application/json. Admin request IDs remain metadata. ZIP bytes
  remain arbitrary opaque bytes; fixture archives do not claim ZIP/domain parity.
- Existing status/payload, handled/status/payload and Admin out-parameter signatures
  are invoked by [consumer adapters](../examples/promptnook_contract/adapters.goose).
  A false handled result leaves response selection untouched.

A legacy contiguous request consumer requires an explicit extra owned copy:
[snapshot.goose](../examples/promptnook_contract/snapshot.goose) preserves method,
raw target and non-framing header spelling/order/duplicates/whitespace, replaces
Content-Length/Transfer-Encoding/Trailer/Expect with one Content-Length for the
fully decoded body, and rejects streamed/unavailable bodies. It is reconstructed
HTTP/1.1, not the original wire image; chunk extensions, trailers and original
protocol version are not retained. Its maximum is 131072 bytes and 128 input
fields, with parser head limits still applied. Do not route already-large buffered
bodies through this compatibility copy blindly; adapt those callers to body/header
views or streaming. [Snapshot tests](../tests/promptnook_snapshot_cases.goose) reparse
binary decoded bytes and reject injected, oversized and unavailable input.

## Explicit capacity choices

The values are current defaults or hard caps, not a promise that all requests fit:

| Boundary | Current default/hard bound | Application decision |
| --- | --- | --- |
| Core buffered request/response | `Limits`: 8 MiB body and output; 8192-byte request line; 16384-byte header line/section; 100 fields; 32768-byte retained head/header budget | Override within a finite memory reservation; body admission and overflow errors are observable. |
| Streamed request body | `RouteOptions.body_bytes_max` sets the streamed route admission/reader limit separately from `Limits.body_bytes_max` buffered storage | Set both intentionally when an application serves buffered and streamed routes; tests reject oversized declarations before 100-continue. |
| Serialized execution handoff | 65536-byte request and response body hard caps, independently of HTTP buffered-body limits | Route larger accepted requests/exports through an application design that does not copy their bodies into lane messages, or reject explicitly. Integration covers an inline chunked body larger than 128 KiB and a serialized body over 64 KiB returning 413; do not claim arbitrary-size native handoff. |
| Client | 4 concurrent requests, queue 16, 16 KiB request/response headers, 64 MiB request/response bodies | Select finite pool, byte and deadline budgets; check admission and typed completion errors. |
| Static mount | 4096-byte path, 8192-byte target/redirect, 128 scanned directory entries, 32768 packed/rendered listing bytes, at most 4 fallbacks | Set smaller caps or use a different application listing policy; skipped entries still count against bounded scanning. |
| File executor | 1–4 workers, 1–64 slots, at most 4096-byte read chunk | Own the executor/root until all jobs drain; a slow peer does not allocate unbounded completed chunks. |
| Portal consumer preparation | 128 environments/pairs, 128-byte selected environment, 4096-byte URL/query, 1024-byte selected Authorization storage | Validate configuration; fail rather than truncate identities, URLs or credentials. |
| Portal audit | 32768-byte response inspection; 4096-byte mutation input; 16 approved lookup keys/values; 1024 bytes per selected field | Treat `limited` as partial evidence and keep completion facts even without a parsed body. |
| E10 route fixture capture/query probes | 256 bytes each | Demonstration cap only; not a new PromptNook business ID constraint. Tests expect explicit 413 rather than buffer overflow. |

Public cap and policy types, not these examples' constants, define an application's
chosen limits. Admission failures, post-commit failures and cancellation are distinct:
render a policy response before commitment when possible; after commitment terminate
the transfer and record its completion outcome without appending a new response.

The integration composes an API runtime with its named native lane and a separate
stream-capable Portal server instance in the same process. Pooled runtime owners
currently use buffered `NoStream` endpoints; files/proxy/SSE use the public typed
stream-server APIs. This supported composition keeps Portal I/O independent of
native database work without inventing a runtime-stream overload. The combined
[Portal integration](../tests/promptnook_portal_integration_test.goose) holds the
API native DB gate while real Portal file and proxy requests finish, then releases
and joins both owners. The API/native, Portal and general-web integrated suites
pass debug and optimized builds locally on macOS; the disposable HTTP/HTTPS
outbound runner also passes both modes. The final [E10.S3 verification](promptnook_requirements.md#final-grouped-verification-results)
adds successful debug/optimized groups on Linux and macOS.

## Remaining application work

A later port must retain actual domain validation/storage, request ID generation,
credentials, environment URLs, reset authorization and CLI modes. Register every
family in the audited route inventory, configure CORS/auth and static policies,
choose limits/deadlines, bind native state to its lane, and connect owned completion
facts to application logs. No ORM, identity provider, ZIP builder or production
migration runner belongs in Silly core. E10.S3 now records successful Linux/macOS
verification and final package/documentation tooling, separately from the historical
E10.S2 local integration results. No required framework feature is designated an unimplemented
extension point by these migration notes.

## Concrete entry-point mapping for the later port

| Existing PromptNook boundary | Public Silly boundary | Application code retained |
| --- | --- | --- |
| `main.goose:main`, `server/server.goose:run` / `run_handle` | Application-owned `main`, `serve` or `run_runtime*`, owned listeners and shutdown handles | CLI modes, environment parsing, migration/seeding/reset policy |
| `server/routes.goose:route_families`, `server/*_routes.goose` | Startup `Router<Route>`, `prepare`, typed `handle` and named raw captures | All 181 audited declaration shapes, method aliases, scoped fallback envelopes and domain dispatch |
| `core/auth.goose`, User/auth/SSO guards | `header` / `header_raw`, terminal endpoint guards and static middleware | Token/session/SSO semantics, permissions, bcrypt and identity precedence |
| `core/http.goose:response`, `response_plain`, `redirect_response`, `zip_response` | `json_bytes`, `bytes`, `redirect`, `attachment`, or owned file responses | Exact JSON/plain payloads, locations, filename policy and ZIP construction |
| `admin/admin.goose:dispatch` and `finish_dispatch` | Consumer `invoke_admin`, `add_header`, `audit_request_id`, lifecycle metadata | Out-parameter calling convention, request ID generation, Admin envelopes and audit schema |
| `ideas`, `flagged`, `mcp_settings`, `mcp_protocol` handled returns | Consumer `invoke_handled` and ordinary response selection | Dispatch/auth/accounting, domain parsing and exact diagnostics |
| `pn_method_path`, `pn_path_segment`, `pn_query_*`, `pn_request_header*`, `pn_request_body` | `Request` / `Context` views, named captures, query compatibility helpers, optional explicit legacy snapshot | Meaning of IDs/cursors/keys, malformed-query policy and raw-body parsers |
| `portal/portal.goose:run` / `proxy` | Separate typed stream server; `static_mount_response`; consumer Portal `prepare` / `start`; `proxy_step_with_policy` | Static root, directory/fallback choice, environment/token selection and error/audit content |
| `pn_mcp_http_get`, `pn_normalize_mcp_url`, integration connection checks | Optional client pool and consumer `begin_check` / `poll_check` / `render_check` | Integration records, quotas, tokens and application messages |
| `turso.c` database/statement/rows, native ZIP assembly | Named `Execution.Serialized` lane; owner Start/Stop; bounded copied work | Actual native bindings and complete indivisible DB/ZIP sequences |
| `pn_install_shutdown_handlers`, `pn_shutdown_requested` | Application-selected signal adapter plus runtime cancellation / `resume_shutdown` | Process lifecycle and exit policy; preserve pending ownership until complete |

This mapping is preparation for a later application change. It does not replace
stores, execute migrations, install production credentials, publish a package,
deploy a listener or claim PromptNook business parity.
