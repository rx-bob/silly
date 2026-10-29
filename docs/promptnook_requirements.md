# PromptNook consumer requirements

This is the E1.S1 source inventory with E10.S1 framework evidence added below.
It is not a PromptNook port or a claim of business parity.
Paths below are relative to `/Users/bob/repos/nook/promptnook/backend/goose`.
The current source, including Admin, Portal, MCP, Ideas and Flagged, governs scope;
older migration parity exclusions do not remove requirements.

## Baseline and coverage

Audit date: 2026-10-26. Repository HEAD: `b930861ecf0da8379a82ff7021c8b05d9217b51f`.
`git status --short -- .` inside the backend reports `?? ./`: this backend is untracked.
The commit therefore does **not** identify the audited code. The accompanying
[promptnook_source_manifest.json](promptnook_source_manifest.json) records SHA-256,
byte counts, declared Goose symbols and canonical native call sites for every source.
Its aggregate identity hashes sorted `relative_path + NUL + file_sha256 + LF` records.
Baseline aggregate SHA-256: `941e4b53a6c31c14f9c7c743255c18f1bca22607600f5374eb6f6e6fce17c51b`.
Generated native `target/` output, executable/data artifacts, and the historical
`docs/web_framework_poc.goose` are excluded. Neither consumer nor PoC was changed.

Exactly **118 non-PoC Goose files** are covered: main 1, admin 38, core 4, db 5,
flagged 4, ideas 9, mcp_protocol 10, mcp_settings 3, nodes 6, portal 2,
projects 11, prompts 4, server 9, turso 1, users 4, workspaces 7.
The manifest additionally freezes native C, build sidecars, README and Taskfile.
Every source is mapped to requirement IDs in the source coverage table below.

The tables retain the audited requirements and original story ownership. The
[E10.S1 coverage ledger](#e10s1-framework-coverage-ledger) maps every row to current
public APIs, executable assertions and retained application dependencies. Component
evidence and consumer fixtures are present; E10.S2 combined-system suites pass locally
in debug/optimized builds. E10.S3 verification below covers macOS and Linux. Application
ownership does not authorize moving domain logic into Silly.

## Route and domain requirements

All route rows require static startup preparation (E3.S1), named raw captures and
exact segment/method handling (E3.S2), bounded request access (E4), and fixtures
(E10.S1/E10.S2). Listed primary owners below identify the distinguishing work.

| ID | Source and symbols | Required behavior | Primary stories | Stays in application |
| --- | --- | --- | --- | --- |
| R01 | `main.goose:main`; `server/server.goose:run`, `run_handle` | Embeddable library; API listener, separate `portal` command/listener and `migrate` mode; caller controls startup and development seeding | E1.S1, E1.S3, E6.S4, E10.S3 | CLI/env policy, seeds, migrations, reset |
| R02 | `server/routes.goose:handle_request_options`, `route_families`; `server/fallback_routes.goose:route_database_health`, `route_fallback` | GET `/`, `/healthz`, `/db/health`; OPTIONS; `/api/test/reset-db`; family dispatch and broad application 404 fallback | E3.S2, E5.S3, E10.S1 | Health payload/DB probe, reset authorization, fallback envelopes |
| R03 | `server/user_routes.goose:route_user` and `route_user_*`; `users/auth.goose`, `profile.goose`, `sso_profiles.goose` | `/api/user`: auth config, signup/login, GET/PATCH me, GET/PUT preferences, SSO login/callback/logout, change-password; preserve redirects, raw identity headers and sessions | E3.S2, E3.S3, E4.S1, E5.S1 | bcrypt, SSO/session/token rules, profile validation |
| R04 | `server/workspace_routes.goose:route_workspaces*`; `workspaces/workspace_crud.goose`, `sharing.goose`, `tree.goose` | Workspace list/create, PATCH/PUT/delete by ID, share/tree/export and collaborators add/update/remove | E3.S2, E4.S3, E10.S1 | Permissions, recursive tree/data and sharing policy |
| R05 | `workspaces/workspace_export.goose:workspace_export_response`; `core/http.goose:zip_response` | Binary ZIP response with attachment filename and arbitrary bytes | E5.S1, E8.S1, E6.S3 | ZIP entries/assembly and zlib |
| R06 | `server/node_routes.goose:route_nodes*`; `nodes/*.goose` | Nodes create/update/delete/duplicate, share, collaborators, variables GET/PUT/PATCH, value-set list/create/update/delete/duplicate | E3.S2, E4.S3, E10.S1 | Node permissions, variable and value-set domain rules |
| R07 | `server/prompt_routes.goose:route_prompts*`; `prompts/*.goose` | Prompt GET and PATCH/PUT, storage PATCH/PUT, share, versions list/detail/restore, collaborators list/add/update/remove; preserve raw IDs and nested segments | E3.S2, E4.S3, E10.S1 | Prompt versioning, content, permissions |
| R08 | `server/project_routes.goose:route_projects*`; `server/project_work_item_routes.goose:route_project_work_items*`; `projects/*.goose` | Projects, initiatives, epics and stories; nested list/create, item mutations/status, story links/criteria/activity; method aliases | E3.S2, E4.S3, E10.S1 | Work-item records, relations and mutation rules |
| R09 | `ideas/lifecycle_dispatch.goose:dispatch`, `dispatch_get*`, `dispatch_validate`, `dispatch_reverse`; `ideas/*.goose` | Ideas list/create/get/PATCH/delete, archive/unarchive/trash/untrash, promote, links to prompts/projects/initiatives/epics/stories and reverse nested lookups | E3.S2, E4.S3, E10.S1 | Lifecycle, promotion, link storage and reverse indexes |
| R10 | `flagged/dispatch.goose:dispatch`, `dispatch_get`; `flagged/*.goose` | Flagged list/create/count/PATCH/PUT/delete; POST `/api/v1/flagged/report`, including `X-Mcp-User-Id` | E3.S2, E4.S1, E10.S1 | Report identity, moderation and storage |
| R11 | `mcp_protocol/dispatch.goose:dispatch`, `dispatch_authenticated_route`; `mcp_protocol/*.goose` | `/api/v1/prompts/list`, detail, run, create, delete; flagged report; token/session errors may be plain payloads | E3.S3, E4.S3, E5.S1, E10.S1 | Protocol authorization, usage accounting, execution and exact JSON diagnostics |
| R12 | `mcp_settings/integration_routes.goose:dispatch`, `dispatch_get`, `test_connection_render`; `mcp_settings/*.goose` | MCP token/regenerate, usage/hourly, calls/recent, integrations CRUD, test-connection; outbound URL/auth/status handling | E3.S2, E9.S4, E10.S1 | Token generation, quotas, integration records |
| R13 | `admin/admin.goose:dispatch`, `dispatch_rid*` | `/api/admin-health`, `/api/admin` scope; meta, users by-email/by-id/directory/workspaces/edit; workspaces by-id/edit/tree; prompts by-id/content/edit; ideas by-id/edit; projects by-id; nodes/value-sets, value-sets/edit, tree-nodes/edit; raw/exact GET/POST and raw/prefix GET | E3.S2, E3.S3, E5.S2, E10.S1 | Admin bearer policy, environment selection, domain edits |
| R14 | `admin/raw*.goose`, `admin/*helpers.goose`, `admin/request_inputs.goose` | Raw key and prefix access, cursor/query fidelity, structured missing/null/invalid storage diagnostics, typed records and synchronization | E4.S2, E4.S3, E10.S2 | Raw schema semantics, DB indexes, audit envelope |
| R15 | `portal/portal.goose:run`, `proxy`, `proxy_response`, `log_audit*` | Separate Portal listener, `/portal-api` proxy scope, environment query selection, static fallback, forwarded identity, completion audit data | E6.S4, E8.S4, E9.S4, E5.S2 | Environment URLs/tokens, audit content and identity policy |

## HTTP, native and helper requirements

`core/ffi.goose` is the canonical declaration module for the HTTP/utility shims.
Most are defined in `http_posix.c`; `pn_user_initials` is defined in
`turso/turso.c:251`, an application dependency that must not leak into Silly core.
Its complete symbol-to-requirement mapping follows this table. Native calls consume
borrowed Goose slices only during a call; future async work must own queued data.

| ID | Source and symbols | Required behavior | Primary stories | Stays in application |
| --- | --- | --- | --- | --- |
| H01 | `http_posix.c:pn_http_read`, `pn_request_line_too_long`, `pn_request_headers_too_large`, `pn_method_path` | HTTP/1.0/1.1 request line, path/query split, bounded header parsing, request-line 414 and fields 431; explicit invalid input outcomes | E2.S1 | Error envelope policy |
| H02 | `http_posix.c:pn_request_content_length`, `pn_request_is_chunked`, `pn_chunked_measure`, `pn_decode_chunked_body` | Fixed-length and chunked bodies, extensions/trailers, split reads, CL/TE ambiguity rejection, truncation; bodies larger than old 128 KiB initial allocation within configured cap | E2.S2 | Body size choices |
| H03 | `http_posix.c:pn_request_expects_continue`, `pn_send_continue` | Validated `Expect: 100-continue`, avoid waiting for body before interim response; unsupported expectations explicit | E2.S2 | Endpoint admission policy |
| H04 | `http_posix.c:pn_http_write`, `pn_http_write_response`, `pn_http_keep_alive`; `server/server.goose:run_handle` | Partial-write progress, HTTP/1.0 and 1.1 connection persistence, ordered pipelining, buffered leftovers, HEAD/no-body framing | E1.S3, E2.S3, E2.S4 | None |
| H05 | `http_posix.c:pn_tcp_listen`, `pn_accept`, `pn_close`, `pn_install_shutdown_handlers`, `pn_shutdown_requested` | Explicit descriptor ownership, nonblocking readiness, cancellation/shutdown and cleanup once across API/Portal listeners | E1.S3, E6.S1, E6.S4 | Process signal installation/CLI choice |
| H06 | `http_posix.c:pn_request_header`, `pn_request_header_raw`; `core/auth.goose`; `portal/portal.goose:log_audit` | Case-insensitive lookup, duplicates in order, trimmed vs trailing-whitespace-preserving values; Authorization, X-Mcp-User-Id, X-Zitadel-User-Id, X-Forwarded-User | E4.S1 | Header-based authentication decisions |
| H07 | `http_posix.c:pn_query_has`, `pn_query_value`, `pn_decode_query_piece`, `pn_path_segment` | Distinguish missing/empty; plus/percent decoding, raw IDs, repeated parameters, invalid-escape compatibility for query; cursor/key/token/environment fidelity | E3.S2, E4.S2 | Query meaning |
| H08 | `core/http.goose:response`, `response_plain`, `admin_http_response`, `redirect_response` | JSON, plain bytes with omitted Content-Type, empty replies, explicit headers, X-Request-Id, 302 Location, content length and status | E2.S3, E5.S1 | JSON envelopes and request ID generation |
| H09 | `core/http.goose:response*`; `server/routes.goose:handle_request_options` | Global/scoped CORS and OPTIONS; configurable policy with correct response lifecycle | E5.S2, E5.S3 | Allowed origins/methods/headers |
| H10 | `*/request_inputs.goose`; `mcp_protocol/json_parser.goose`, `request_models.goose`; `admin/raw_schema*` | Raw-body escape hatch, camelCase, nested collections, missing/null and duplicate-key behavior; custom readers/writers and precise diagnostic locations | E4.S3, E10.S2 | Domain JSON models and error text |
| H11 | `admin/admin.goose:log_request`, `finish_dispatch`; `portal/portal.goose:log_audit*` | Before/after endpoint guards, completion/cancel callback data, request ID propagation; no late response replacement | E3.S3, E5.S2, E5.S3 | Audit schema/content, auth and rate-limit accounting |
| H12 | `turso/turso.c` global database/statement/rows; `http_posix.c` global ZIP assembly | Single process-wide serialized native execution lane, bounded queue and owned copied messages, stale generation protection | E1.S4, E6.S2, E6.S3 | Turso/bcrypt/ZIP adapters; future conversion to reentrant state |
| H13 | `http_posix.c:pn_portal_static`, `pn_mime_type` | GET/HEAD files, MIME, canonical rooted resolution and traversal/symlink containment; bounded file transfers and disconnect cleanup | E8.S1, E8.S2 | Static root and access policy |
| H14 | `http_posix.c:pn_static_not_modified`, `pn_static_header` | ETag/Last-Modified conditionals, 304; HEAD headers without body | E8.S2 | Cache policy |
| H15 | `http_posix.c:pn_static_parse_ranges`, `pn_static_multipart_boundary` | Single/multiple/suffix/open ranges, 206 and 416, valid multipart/byteranges, bounded counts and streaming | E8.S3 | Range limits |
| H16 | `http_posix.c:pn_portal_static`, `pn_static_append_listing`, `pn_static_html`, `pn_static_uri_path` | Directory listing/fallback, escaped HTML/names, slash redirects retaining query; fresh precompressed .gz siblings and representation-aware metadata/ranges | E8.S4 | Portal fallback policy |
| H17 | `http_posix.c:pn_portal_build_url`, `pn_portal_proxy`, `pn_header_is_hop` | Join base/path, filter environment selectors, preserve repeated query values, supplied/forwarded Authorization, upstream status/headers, filter hop-by-hop headers and propagate cancellation/backpressure | E9.S1, E9.S3, E9.S4 | Destination selection and tokens |
| H18 | `http_posix.c:pn_mcp_http_get`, `pn_normalize_mcp_url`, `pn_portal_connect_error` | HTTP/HTTPS outbound transport, URL validation, explicit vs implicit compression/decoding, transport-error mapping, bounded response data | E9.S1, E9.S2, E9.S4 | MCP URL conventions, error envelope/text |
| H19 | `core/ffi.goose:pn_zip_*`, `pn_uuid_v4`, token/time/CRC/UTF-8 helpers; `turso/turso.goose:pn_db_*`, `pn_password_*` | Application adapters remain callable in serialized lane; core consumer links no database, password, zlib or outbound TLS libraries | E1.S1, E6.S3, E10.S3 | All listed utility/database/password/ZIP implementations |
| H20 | General framework scope; `reference/responses.goose`, `request_stream.goose`, `streaming.goose` in Silly | HTML escaping/forms, streamed request bodies, bounded output streams/SSE, owned resumable states | E4.S2, E5.S1, E7.S1, E7.S2, E7.S3 | Templates, event payloads and application stream state |

## Deliberate compatibility changes

These are required corrections, not missing capabilities. The complete source-derived
old/new matrix, concrete tests and later port actions are in
[migration notes](migration_notes.md). The original high-level inventory follows:

| Evidence | Required Silly behavior | Owning story |
| --- | --- | --- |
| `pn_portal_static` detects HEAD but writes file/range/listing bytes | Suppress all HEAD bodies while retaining representation metadata | E2.S3, E8.S2, E8.S3, E8.S4 |
| `pn_portal_static` emits `multipart/byterange` | Emit valid `multipart/byteranges` and bounded framing | E8.S3 |
| `pn_request_content_length` permissive numeric parsing | Strict digit/overflow/framing validation | E2.S1, E2.S2 |
| Some `server/*routes` predicates omit end-segment checks; Portal uses `starts_with("/portal-api")` | Exact segment/mount matching, explicit catch-all policy | E3.S2, E9.S4 |
| Native reads/whole-file/proxy buffering grow without framework caps; writes hide failures | Named caps, explicit failure/cancellation and bounded backpressure | E2.S2, E6.S1, E7.S1, E8.S1, E9.S3 |

No WebSockets or multipart-upload requirement was found. Incoming TLS remains
external termination; initial platform scope is Linux/macOS, incoming HTTP/1.0
and HTTP/1.1, outgoing HTTP/HTTPS. Business models, ORM/identity services, database
migrations and ZIP construction remain outside framework scope.

## Canonical native declaration coverage

All 34 declarations in `core/ffi.goose` are assigned below. The 22
`pn_db_*`/`pn_password_*` declarations in `turso/turso.goose` belong to H12/H19,
remain application-owned, and are listed individually in the source manifest.

| Symbol | Requirements |
| --- | --- |
| `pn_accept` | H05 |
| `pn_close` | H05 |
| `pn_crc32_hex` | H19 |
| `pn_http_keep_alive` | H04 |
| `pn_http_read` | H01, H02, H03 |
| `pn_http_write` | H04 |
| `pn_http_write_response` | H04 |
| `pn_install_shutdown_handlers` | H05 |
| `pn_live_token` | H19 |
| `pn_mcp_http_get` | H18 |
| `pn_method_path` | H01 |
| `pn_next_month_reset` | H19 |
| `pn_normalize_mcp_url` | H18 |
| `pn_path_segment` | H07 |
| `pn_portal_has_url_config` | R15, H19 |
| `pn_portal_proxy` | H17, H18 |
| `pn_portal_query_json` | R15, H07 |
| `pn_portal_static` | H13, H14, H15, H16 |
| `pn_query_has` | H07 |
| `pn_query_value` | H07 |
| `pn_request_body` | H02, H10 |
| `pn_request_header` | H06 |
| `pn_request_header_raw` | H06 |
| `pn_request_id` | H11, H19 |
| `pn_session_token` | H19 |
| `pn_shutdown_requested` | H05 |
| `pn_tcp_listen` | H05 |
| `pn_unix_rfc3339` | H19 |
| `pn_user_initials` | H19 |
| `pn_utf8_valid` | H19 |
| `pn_uuid_v4` | H19 |
| `pn_zip_add` | R05, H12, H19 |
| `pn_zip_finish` | R05, H12, H19 |
| `pn_zip_reset` | R05, H12, H19 |

## Source coverage

Full hashes and declared symbols are in the manifest. This table binds every
audited file to the behavioral rows above; it is not a claim of implementation.
Native generated dependency sources are excluded; `turso/turso.c` is included.

| Source | Requirement IDs |
| --- | --- |
| `README.md` | R01, H19 |
| `Taskfile.yml` | R01, H19 |
| `admin/admin.goose` | R13, R14, H06, H07, H10, H11, H12 |
| `admin/entities.goose` | R13, R14, H06, H07, H10, H11, H12 |
| `admin/entity_read_helpers.goose` | R13, R14, H06, H07, H10, H11, H12 |
| `admin/idea_edits.goose` | R13, R14, H06, H07, H10, H11, H12 |
| `admin/project_details.goose` | R13, R14, H06, H07, H10, H11, H12 |
| `admin/project_prompt_helpers.goose` | R13, R14, H06, H07, H10, H11, H12 |
| `admin/raw.goose` | R13, R14, H06, H07, H10, H11, H12 |
| `admin/raw_account_sync.goose` | R13, R14, H06, H07, H10, H11, H12 |
| `admin/raw_auxiliary_schemas.goose` | R13, R14, H06, H07, H10, H11, H12 |
| `admin/raw_decoding.goose` | R13, R14, H06, H07, H10, H11, H12 |
| `admin/raw_entity_records.goose` | R13, R14, H06, H07, H10, H11, H12 |
| `admin/raw_indexes.goose` | R13, R14, H06, H07, H10, H11, H12 |
| `admin/raw_invite_errors.goose` | R13, R14, H06, H07, H10, H11, H12 |
| `admin/raw_node_indexes.goose` | R13, R14, H06, H07, H10, H11, H12 |
| `admin/raw_prefix_queries.goose` | R13, R14, H06, H07, H10, H11, H12 |
| `admin/raw_prefix_scans.goose` | R13, R14, H06, H07, H10, H11, H12 |
| `admin/raw_records.goose` | R13, R14, H06, H07, H10, H11, H12 |
| `admin/raw_rendering.goose` | R13, R14, H06, H07, H10, H11, H12 |
| `admin/raw_schema.goose` | R13, R14, H06, H07, H10, H11, H12 |
| `admin/raw_schema_errors.goose` | R13, R14, H06, H07, H10, H11, H12 |
| `admin/raw_schema_matches.goose` | R13, R14, H06, H07, H10, H11, H12 |
| `admin/raw_schema_record_errors.goose` | R13, R14, H06, H07, H10, H11, H12 |
| `admin/raw_schema_story_errors.goose` | R13, R14, H06, H07, H10, H11, H12 |
| `admin/raw_summaries.goose` | R13, R14, H06, H07, H10, H11, H12 |
| `admin/raw_sync_dispatch.goose` | R13, R14, H06, H07, H10, H11, H12 |
| `admin/raw_typed_lookup.goose` | R13, R14, H06, H07, H10, H11, H12 |
| `admin/raw_update_responses.goose` | R13, R14, H06, H07, H10, H11, H12 |
| `admin/raw_updates.goose` | R13, R14, H06, H07, H10, H11, H12 |
| `admin/raw_value_set_indexes.goose` | R13, R14, H06, H07, H10, H11, H12 |
| `admin/raw_work_item_records.goose` | R13, R14, H06, H07, H10, H11, H12 |
| `admin/request_inputs.goose` | R13, R14, H06, H07, H10, H11, H12 |
| `admin/tree_node_helpers.goose` | R13, R14, H06, H07, H10, H11, H12 |
| `admin/user_directory.goose` | R13, R14, H06, H07, H10, H11, H12 |
| `admin/user_edits.goose` | R13, R14, H06, H07, H10, H11, H12 |
| `admin/user_workspaces.goose` | R13, R14, H06, H07, H10, H11, H12 |
| `admin/users.goose` | R13, R14, H06, H07, H10, H11, H12 |
| `admin/value_set_helpers.goose` | R13, R14, H06, H07, H10, H11, H12 |
| `admin/workspace_edits.goose` | R13, R14, H06, H07, H10, H11, H12 |
| `core/auth.goose` | H06, H07, H08, H09, H19 |
| `core/common.goose` | H06, H07, H08, H09, H19 |
| `core/ffi.goose` | H06, H07, H08, H09, H19 |
| `core/http.goose` | H06, H07, H08, H09, H19 |
| `db/late_migrations.goose` | R01, R02, H12 |
| `db/migration_indexes.goose` | R01, R02, H12 |
| `db/migration_sql.goose` | R01, R02, H12 |
| `db/migrations.goose` | R01, R02, H12 |
| `db/reset.goose` | R01, R02, H12 |
| `flagged/dispatch.goose` | R10, H06, H10 |
| `flagged/flagged.goose` | R10, H06, H10 |
| `flagged/flagged_mutations.goose` | R10, H06, H10 |
| `flagged/request_inputs.goose` | R10, H06, H10 |
| `http_posix.c` | H01–H07, H12–H19 |
| `ideas/idea_lifecycle.goose` | R09, H07, H10 |
| `ideas/idea_lists.goose` | R09, H07, H10 |
| `ideas/idea_promotion.goose` | R09, H07, H10 |
| `ideas/ideas.goose` | R09, H07, H10 |
| `ideas/json_errors.goose` | R09, H07, H10 |
| `ideas/lifecycle.goose` | R09, H07, H10 |
| `ideas/lifecycle_dispatch.goose` | R09, H07, H10 |
| `ideas/request_inputs.goose` | R09, H07, H10 |
| `ideas/reverse_indexes.goose` | R09, H07, H10 |
| `main.build` | R01, H19 |
| `main.goose` | R01, H19 |
| `mcp_protocol/dispatch.goose` | R11, H06, H07, H10 |
| `mcp_protocol/json_parser.goose` | R11, H06, H07, H10 |
| `mcp_protocol/mcp_protocol.goose` | R11, H06, H07, H10 |
| `mcp_protocol/model_errors.goose` | R11, H06, H07, H10 |
| `mcp_protocol/prompt_details.goose` | R11, H06, H07, H10 |
| `mcp_protocol/prompt_execution.goose` | R11, H06, H07, H10 |
| `mcp_protocol/prompt_lists.goose` | R11, H06, H07, H10 |
| `mcp_protocol/recent_calls_errors.goose` | R11, H06, H07, H10 |
| `mcp_protocol/request_inputs.goose` | R11, H06, H07, H10 |
| `mcp_protocol/request_models.goose` | R11, H06, H07, H10 |
| `mcp_settings/integration_routes.goose` | R12, H07, H10, H18 |
| `mcp_settings/mcp_settings.goose` | R12, H07, H10, H18 |
| `mcp_settings/usage_responses.goose` | R12, H07, H10, H18 |
| `nodes/node_duplication.goose` | R06, H10 |
| `nodes/node_updates.goose` | R06, H10 |
| `nodes/nodes.goose` | R06, H10 |
| `nodes/request_inputs.goose` | R06, H10 |
| `nodes/sharing_and_variables.goose` | R06, H10 |
| `nodes/value_sets.goose` | R06, H10 |
| `portal/portal.goose` | R15, H05, H11, H13, H14, H15, H16, H17 |
| `portal/request_inputs.goose` | R15, H05, H11, H13, H14, H15, H16, H17 |
| `projects/epic_handlers.goose` | R08, H07, H10 |
| `projects/epic_lists.goose` | R08, H07, H10 |
| `projects/epics.goose` | R08, H07, H10 |
| `projects/initiative_handlers.goose` | R08, H07, H10 |
| `projects/project_handlers.goose` | R08, H07, H10 |
| `projects/projects.goose` | R08, H07, H10 |
| `projects/request_inputs.goose` | R08, H07, H10 |
| `projects/stories.goose` | R08, H07, H10 |
| `projects/story_actions.goose` | R08, H07, H10 |
| `projects/story_mutations.goose` | R08, H07, H10 |
| `projects/work_item_records.goose` | R08, H07, H10 |
| `prompts/collaborators.goose` | R07, H10 |
| `prompts/prompt_versions.goose` | R07, H10 |
| `prompts/prompts.goose` | R07, H10 |
| `prompts/request_inputs.goose` | R07, H10 |
| `server/fallback_routes.goose` | R01, R02, R03, R04, R06, R07, R08, H01, H02, H03, H04, H05, H09 |
| `server/node_routes.goose` | R01, R02, R03, R04, R06, R07, R08, H01, H02, H03, H04, H05, H09 |
| `server/project_routes.goose` | R01, R02, R03, R04, R06, R07, R08, H01, H02, H03, H04, H05, H09 |
| `server/project_work_item_routes.goose` | R01, R02, R03, R04, R06, R07, R08, H01, H02, H03, H04, H05, H09 |
| `server/prompt_routes.goose` | R01, R02, R03, R04, R06, R07, R08, H01, H02, H03, H04, H05, H09 |
| `server/routes.goose` | R01, R02, R03, R04, R06, R07, R08, H01, H02, H03, H04, H05, H09 |
| `server/server.goose` | R01, R02, R03, R04, R06, R07, R08, H01, H02, H03, H04, H05, H09 |
| `server/user_routes.goose` | R01, R02, R03, R04, R06, R07, R08, H01, H02, H03, H04, H05, H09 |
| `server/workspace_routes.goose` | R01, R02, R03, R04, R06, R07, R08, H01, H02, H03, H04, H05, H09 |
| `turso/turso.build` | H12, H19 |
| `turso/turso.c` | H12, H19 |
| `turso/turso.goose` | H12, H19 |
| `users/auth.goose` | R03, H06, H08, H10, H19 |
| `users/bootstrap.goose` | R03, H06, H08, H10, H19 |
| `users/profile.goose` | R03, H06, H08, H10, H19 |
| `users/sso_profiles.goose` | R03, H06, H08, H10, H19 |
| `workspaces/request_inputs.goose` | R04, R05, H10, H12 |
| `workspaces/sharing.goose` | R04, R05, H10, H12 |
| `workspaces/tree.goose` | R04, R05, H10, H12 |
| `workspaces/workspace_crud.goose` | R04, R05, H10, H12 |
| `workspaces/workspace_deletion.goose` | R04, R05, H10, H12 |
| `workspaces/workspace_export.goose` | R04, R05, H10, H12 |
| `workspaces/workspaces.goose` | R04, R05, H10, H12 |

## Inventory verification

The audit checked equality between the 118 non-PoC `.goose` paths on disk and
the manifest, and equality between all canonical `core/ffi.goose` declarations
and the mapping above. Hashes represent working-tree content, including untracked
files. Changes to that content require re-audit, not a silent update of hashes.
The manifest records the exact declared Goose symbols for tracing domain helpers
that share a requirement. E10.S1 turns these rows into executable contract cases;
E10.S2 attaches local integrated results below and explicit migration actions in
[migration notes](migration_notes.md); this does not claim domain parity.

E1.S1 validation result: **passed**. All 118 actual source paths equal the manifest
set and each has a nonempty requirement mapping; all 124 file hashes still match
working-tree bytes; all 34 canonical HTTP/utility FFI declarations have explicit
requirement rows, and all 22 Turso/password declarations appear in the manifest
under the H12/H19 assignment. No source or canonical declaration is unmatched.

## E6.S3 native ownership boundary

Rechecked the actual consumer sources at the path above on 2026-10-27. This section
records the concurrency boundary; it does not replace or silently refresh the E1.S1
source manifest, and the consumer has not been ported or modified.

| Mutable native state | Source | Required owner and lifetime |
| --- | --- | --- |
| `database`, `connection`, `statement`, `rows`, `row` | `turso/turso.c:15–19` | The one named `promptnook_native` lane owns open, prepare/bind/execute/query/next/column access and close. `pn_db_prepare` destroys the previous row, row-set and statement, so serializing individual FFI calls is insufficient. |
| `changed_rows`, `inserted_id`, `error_text[512]`, `opened` | `turso/turso.c:20–23` | Read results/errors and readiness on that same lane as the operation producing them; another call may overwrite this global state. |
| `pn_zip_local`, its length/capacity, `pn_zip_central`, its length/capacity, `pn_zip_entries` | `http_posix.c:971–975` | Keep the entire reset/add/finish sequence on the same named lane. `pn_zip_reset` frees shared assembly buffers; `pn_zip_finish` copies bytes into the caller's owned output. Cleanup must reset/release retained buffers on the lane. |
| `pn_stop_requested` (`volatile sig_atomic_t`) | `http_posix.c:47` | Process signal/control policy, separate from the native application lane. Retain one application-owned signal integration; E6.S3 does not move signal handling into endpoint callbacks. |

The corresponding Turso operations are `pn_db_open` at line 44, `pn_db_close` at 85,
`pn_db_exec` at 96, `pn_db_prepare` at 107, bind calls at 121–145,
`pn_db_execute` at 151, `pn_db_query` at 163, `pn_db_next` at 173,
column accessors at 181–226, and result/error accessors at 235–237. ZIP reset/add/finish
start at `http_posix.c:1014`, `1021`, and `1084`. Native dependency internals are not
claimed thread-safe by this inventory.

Concrete migration call sites also include:

- `server/server.goose:17–29`: development-auth connect/seed/close currently occurs before
  listening. In a concurrent integration, move that native sequence into the named lane's
  Start callback; configuration-only I/O initializers do not call it.
- `server/routes.goose:151–166`: `/api/test/reset-db` connects, resets, and closes native
  state inside a request. Assign its entire endpoint and middleware to the named lane.
- `db/migrations.goose:6` onward: `migrate_database` opens, prepares/queries, executes,
  closes and may exit on failure. Keep the migration CLI separate, or deliberately adapt
  the entire operation to the same lane if an online migration path is introduced.
- `workspaces/workspace_export.goose:238–278`: archive construction resets global ZIP
  state, adds metadata and entries in a loop, then finishes. Keep database reads, entry
  construction and ZIP assembly within the same endpoint execution boundary.

Register `ExecutorOptions { serialized_name: "promptnook_native", lanes: 1, .. }` and
assign all native-dependent routes—including native authentication/readiness middleware,
admin operations, database health, reset, and export—to `Execution.Serialized` with that
exact name. Scope inheritance provides this boundary; explicitly inline routes must not
touch those globals. `/healthz` can remain inline if it only returns static process health.
The framework validates a bounded name and binds it to lane zero. Numeric extra lanes,
when explicitly permitted, must not touch this consumer's Turso or ZIP globals.

`Owner.is_serialized("promptnook_native")` gates native Start/Stop. The reference keeps
initialization pure and remembers whether native Start was attempted so Stop can clean
partial initialization once. HandlerFinished runs on the lane; TransferFinished runs on
the I/O owner and therefore must not query or clean native state. Error renderers used
by I/O admission failures also remain pure and nonblocking.

Goose app owners are independent, but C globals are still process-wide. The runtime's
single process-wide lease and one named lane provide the framework registration boundary;
they do not protect against application code calling these FFI functions directly from
another thread. Scaling these handlers across CPU cores requires application changes to
explicit native handles, genuine thread-local state, or process isolation. Independent
socket workers can already serve static/nonblocking routes while native work is busy.

The executable contract example and test use a small C state-machine fixture, not libSQL,
bcrypt, zlib, consumer business logic, or production native sources. Example/test build
sidecars link that fixture locally; `silly.build` retains only its core control/file/transport sources. The original
consumer symbol inventory and E10 compatibility work remain separate requirements.

## E9.S4 outbound evidence

R12 outbound checks, R15 Portal proxy/audit, H17 forwarding and H18 client semantics
now map to ordinary public consumer modules and executable local HTTP/HTTPS fixtures.
See [outbound consumer contracts](promptnook_outbound.md) for the source-to-test matrix,
exact selector/auth/query quirks, bounded audit policy and intentional differences.
Production configuration and business code remain untouched; other portions of R12/R15
are covered by their owning stories and E10 consumer fixtures.


## E10.S1 framework coverage ledger

The links below are concrete executable evidence, not a promise that a stub runs
PromptNook's business logic. Public APIs are imported from `silly` or the optional
`client`/`proxy` package. The [consumer route fixture](../examples/promptnook_contract/routes.goose)
and [route contract suite](../tests/integration/promptnook/promptnook_routes_test.goose) use deterministic
application handlers; the [route inventory](../tests/fixtures/promptnook_contracts.json)
records source-observed method/path shapes. The
[legacy adapters](../examples/promptnook_contract/adapters.goose) keep handler
calling conventions outside the core writer and transport. The
[complete reference application](../reference/promptnook.goose) wires these inert
handlers to typed lifecycle callbacks and a named serialized lane; it does not
link real stores or native business libraries.

Each row identifies an application owner even when the framework mechanism is
complete. An executable assertion is component evidence; it does not establish
that every branch has been exercised together on both supported operating systems.

| ID | Public API and concrete contract evidence | Retained application owner / remaining integration |
| --- | --- | --- |
| R01 | `serve`, `run_runtime_listeners_with_executor`, `Request.listener_id`; [package import](../tests/support/consumer_import.goose), [API/Portal listener shutdown](../tests/runtime/shutdown_listeners_test.goose) | Application owns CLI mode selection, migrations, env loading, seeds and reset policy. E10.S2 joins these owners in the integrated suites below; E10.S3 documents final embedding commands. |
| R02 | `Router`, `prepare`, `dispatch_route`, `CorsPolicy`; [complete route contracts](../tests/integration/promptnook/promptnook_routes_test.goose), [CORS socket contracts](../tests/policy/cors_server_test.goose) | Health/DB payload, reset authorization and fallback JSON remain application code. Fixture health/reset have no DB effects. |
| R03 | `Context.param`, `header_raw`, `reject_*`, `respond_redirect`; [User/auth/SSO routes](../tests/integration/promptnook/promptnook_routes_test.goose), [header auth semantics](../tests/request/header_auth_test.goose), [legacy responses](../tests/integration/promptnook/promptnook_adapters_test.goose) | bcrypt, SSO, session issuance, identity and profile rules remain in `users`. Fixture credentials are inert guard inputs. |
| R04 | `Router` named captures and method registration, `Context.body`; [Workspace routes](../tests/integration/promptnook/promptnook_routes_test.goose), [adapter inputs](../tests/integration/promptnook/promptnook_adapters_test.goose) | `workspaces` owns permission checks, sharing, recursive trees and collaborator storage. |
| R05 | `respond_attachment`, `file_response`, `Execution.Serialized`; [binary export adapter](../tests/integration/promptnook/promptnook_adapters_test.goose), [file transfer](../tests/files/file_transfer_test.goose), [whole ZIP sequence ownership](../tests/runtime/native_state_test.goose) | Workspace export builds ZIP entries; zlib/ZIP globals remain native application dependencies. Synthetic bytes prove transport fidelity, not archive correctness. |
| R06 | Prepared routing, named raw captures, `Context.body`; [Nodes/value-set routes](../tests/integration/promptnook/promptnook_routes_test.goose) | `nodes` owns permissions, variable validation and value-set records. |
| R07 | Prepared routing, named raw captures, `Context.body`; [Prompts/version/collaborator routes](../tests/integration/promptnook/promptnook_routes_test.goose), [raw captures](../tests/routing/route_captures_test.goose) | `prompts` owns version history, storage, content and permission rules. |
| R08 | Prepared routing and explicit method aliases; [Projects/work-item routes](../tests/integration/promptnook/promptnook_routes_test.goose) | `projects` owns initiatives, epics, stories, criteria, links, activity and mutations. |
| R09 | Prepared routing and query/body views; [Ideas/link/reverse routes](../tests/integration/promptnook/promptnook_routes_test.goose), [handled tuple adapter](../tests/integration/promptnook/promptnook_adapters_test.goose) | `ideas` owns lifecycle, promotion and relationship indexes. |
| R10 | Prepared routing, `header_raw`; [Flagged routes](../tests/integration/promptnook/promptnook_routes_test.goose), [identity headers](../tests/request/header_auth_test.goose) | `flagged` owns report identity validation, moderation and storage. |
| R11 | Guard boundary, `respond_bytes` with omitted Content-Type; [MCP protocol routes](../tests/integration/promptnook/promptnook_routes_test.goose), [plain errors and handled returns](../tests/integration/promptnook/promptnook_adapters_test.goose) | MCP token/session validation, usage accounting and prompt execution remain application code. |
| R12 | Prepared routing and optional client `submit_request`/response reads; [MCP settings routes](../tests/integration/promptnook/promptnook_routes_test.goose), [local MCP HTTP/HTTPS checks](../tests/integration/promptnook/promptnook_proxy_test.goose) | `mcp_settings` owns tokens, quotas and integration records. [Outbound contract details](promptnook_outbound.md) describe URL/error policies. |
| R13 | Exact routing, named captures, query access, `add_header`; [Admin and admin-health routes](../tests/integration/promptnook/promptnook_routes_test.goose), [admin metadata adapter](../tests/integration/promptnook/promptnook_adapters_test.goose) | `admin` owns bearer/environment policy, record edits and request ID generation. Query-only identifiers stay out of route captures. |
| R14 | `raw_query`, `parse_query`, `query_literal_invalid_escape`, raw body/JSON reader; [query compatibility](../tests/request/query_compat_test.goose), [application JSON diagnostics](../tests/json/json_raw_test.goose), [legacy input boundary](../tests/integration/promptnook/promptnook_adapters_test.goose) | Admin raw schemas, DB indexes, synchronization and error envelopes remain application code. [Migration deltas](migration_notes.md) are explicit; no database parity claim. |
| R15 | Separate listeners, exact scoped routing, `static_mount_response`, `proxy_response`, owned completion data; [Portal route scope](../tests/integration/promptnook/promptnook_routes_test.goose), [static Portal cases](../tests/integration/static_portal/static_portal_test.goose), [outbound/audit contracts](../tests/integration/promptnook/promptnook_proxy_test.goose) | Portal chooses static root, env URLs/tokens and audit policy. Fixture upstreams are disposable local processes. |
| H01 | `scan_head`, `parse_head`, `Limits`; [head grammar](../tests/http/http_head_test.goose), [classified bounds](../tests/http/http_head_limits_test.goose), [invalid requests](../tests/http/http_head_invalid_test.goose) | Application chooses error rendering. Strict framing replaces permissive native parsing. |
| H02 | `BodyReader`, `read_body`, `collect_body`; [body decoding](../tests/http/http_body_test.goose), [invalid framing](../tests/http/http_body_invalid_test.goose), [large/split requests and truncation](../tests/http/http_body_server_test.goose) | Application chooses body caps; decoded snapshots incur an explicit extra copy. |
| H03 | Prepared route/body admission and `BodyMode`; [continue negotiation, unsupported expectations and pre-body rejection](../tests/http/http_body_server_test.goose) | Endpoint admission policy remains application-owned. No handler must manually write an interim wire response. |
| H04 | `Response`, `prepare_response_head`, managed server I/O; [HEAD/no-body wire plans](../tests/http/http_response_test.goose), [partial writes](../tests/http/http_wire_test.goose), [persistence/pipelining](../tests/http/http_connection_test.goose) | No business dependency. The E10.S2 integrated suites below verify combined consumer behavior under failure. |
| H05 | Owned transport descriptors, `run_runtime_listeners`, `resume_shutdown`; [multi-listener shutdown](../tests/runtime/shutdown_listeners_test.goose), [resumable shutdown](../tests/runtime/shutdown_resume_test.goose), [signal adapter](../tests/runtime/signal_adapter_test.goose) | Process signal installation, listener addresses and CLI policy stay with application. |
| H06 | `header`, `header_raw`, `header_wire`, `header_values`, `FieldValue.present`; [header access](../tests/request/header_access_server_test.goose), [identity/auth values](../tests/request/header_auth_test.goose), [legacy snapshot fidelity](../tests/integration/promptnook/promptnook_adapters_test.goose) | Application determines identity precedence and bearer semantics. |
| H07 | `Context.param`, `raw_query`, `parse_query`, compatibility decode policy; [raw captures](../tests/routing/route_captures_test.goose), [missing/empty/repeated compatibility](../tests/request/query_compat_test.goose), [query-only route identifiers](../tests/integration/promptnook/promptnook_routes_test.goose) | Cursor, key, token and environment meanings stay with callers. |
| H08 | `respond_bytes`, `respond_redirect`, `respond_attachment`, `add_header`; [response helpers](../tests/response/responses_test.goose), [legacy status/body/admin contracts](../tests/integration/promptnook/promptnook_adapters_test.goose), [wire framing](../tests/http/http_response_test.goose) | JSON envelopes, diagnostics, request ID generation and attachment naming stay with application. Wire response import is not added. |
| H09 | `CorsPolicy`, router policy scopes and error policy; [CORS decision/writer contracts](../tests/policy/cors_test.goose), [live preflight and response lifecycle](../tests/policy/cors_server_test.goose), [error policy](../tests/policy/error_policy_test.goose) | Application sets origins, methods and allowed headers. |
| H10 | `Context.body`, `json_reader`, `JsonValue`, `json_bytes`; [opaque bodies, duplicate policy and precise application errors](../tests/json/json_raw_test.goose), [missing/null views](../tests/json/json_view_test.goose), [adapter preservation](../tests/integration/promptnook/promptnook_adapters_test.goose) | Domain readers/writers and exact JSON diagnostics remain in each consumer module. |
| H11 | `middleware`, `audit_request_id`, bounded audit payloads, `Lifecycle`; [guard ordering](../tests/handlers/middleware_test.goose), [delivery/cancellation lifecycle](../tests/runtime/lifecycle_server_test.goose), [Portal audit inputs](../tests/integration/promptnook/promptnook_audit_cases.goose) | Application supplies auth/rate-limit decisions, audit schema, redaction and persistence. Completion callbacks never acquire a response builder. |
| H12 | `Execution.Serialized`, `ExecutorOptions.serialized_name`, `Owner.is_serialized`; [native DB/ZIP state detector and sequences](../tests/runtime/native_state_test.goose), [serialized registration](../tests/runtime/serialized_lane_test.goose), [generation routing](../tests/routing/queue_routing_test.goose) | Turso/password/ZIP sequences stay wholly on the application lane. Test C state is a detector, not those libraries. E10.S2 combines the gated lane with real Portal file/proxy operations in the same process. |
| H13 | `open_file_root`, `open_file`, `file_response`, `static_mount_response`; [rooted containment/ownership](../tests/files/files_test.goose), [MIME/HEAD metadata](../tests/files/static_metadata_test.goose), [transfer cleanup](../tests/files/file_transfer_test.goose) | Static root and authorization policy belong to Portal. |
| H14 | `FileValidator`, `file_metadata`, managed file responses; [conditional GET/HEAD and validator replacement](../tests/files/static_metadata_test.goose), [condition precedence](../tests/files/file_conditions_test.goose) | Caller chooses cache validators/policy. |
| H15 | `parse_file_ranges`, managed `FileTransfer`; [range forms and caps](../tests/files/file_ranges_test.goose), [multipart framing](../tests/files/file_multipart_test.goose), [wire 206/416/HEAD](../tests/files/file_ranges_socket_test.goose) | Application chooses range caps. Correct plural multipart media type is an intentional compatibility correction. |
| H16 | `static_mount_response`, `FileMount`/`StaticAction`, `StaticTransfer`; [listings, redirects, fallback, gzip metadata/ranges](../tests/support/static_portal_cases.goose), executed by [Portal static suite](../tests/integration/static_portal/static_portal_test.goose) | Application owns fallback selection and root. HEAD bodies are deliberately suppressed. |
| H17 | Optional `proxy_response`, `proxy_step_with_policy`, `ProxyOptions`; [streamed proxy contracts](../tests/client/proxy_test.goose), [consumer selector/auth/query forwarding](../tests/integration/promptnook/promptnook_proxy_test.goose) | Portal owns destination/token selection; [outbound matrix](promptnook_outbound.md) records quirks and bounded audit choices. |
| H18 | Optional client `ClientOptions`, `submit_request`, response reads and `abandon`; [HTTP status/headers/decode](../tests/client/client_http_test.goose), [Portal/MCP HTTP/HTTPS and typed errors](../tests/integration/promptnook/promptnook_proxy_test.goose) | MCP normalization and error messages remain consumer adapters. Local TLS fixtures avoid configured environments. |
| H19 | Core `silly` import, named serialized execution and owned request/work messages; [core import](../tests/support/consumer_import.goose), [native adapter linkage](../tests/runtime/native_state_test.goose); [core build manifest](../silly.build) | Database/password/UUID/time/CRC/UTF-8/token/ZIP utilities remain application dependencies. Core manifest builds control/file/transport sources only; outbound TLS/zlib stay optional. The README provides final packaging instructions. |
| H20 | HTML/form helpers, `BodyMode.Streamed`, owned `StreamStart`, `SseEvent`; [HTML](../tests/response/html_test.goose), [forms](../tests/request/form_server_test.goose), [streamed request/response cleanup](../tests/streaming/stream_http_test.goose), [SSE socket contracts](../tests/streaming/sse_server_test.goose) | Templates, event payloads and application stream state stay with callers. |

### Route inventory recheck

E10.S1 declares 181 route entries: 178 for the API fixture and three for Portal,
including OPTIONS and scoped/global fallbacks. This count is not a count of
business endpoints. Independent review against the dispatcher predicates found
14 Project entries, 19 work-item entries, 20 explicit Admin entries plus Admin
fallback and admin-health, and the complete methods/aliases in the other families.
The JSON inventory retains source paths and sample requests alongside each entry.

The earlier E3 illustrative inventory contained incorrect paths. Source recheck
uses `/api/user/auth/config`, `/api/user/auth/sso/*`, and
`POST /api/mcp/test-connection`. Idea promotion requires the final kind segment
(`project`, `initiative`, `epic`, or `story`). Story activity is POST; the source
has no `/api/initiatives/:id/epics` route. MCP detail/delete identifiers use query
key `id`; Admin keys retain names such as `workspace_id`, `user_id`, `key` and
`prefix`. The reset fixture retains the source's unrestricted method predicate,
with global OPTIONS handled separately. These are inventory corrections, not
intentional application API changes.

Exact terminal matching and the `/portal-api` segment boundary are deliberate
changes already required by the plan. Scoped fallback tests retain application
404 behavior for wrong methods and unmatched descendants. Portal's static route
fixture proves routing only; file and upstream semantics remain backed by the
separate E8/E9 suites linked above.

### Legacy adapter boundary

`promptnook_adapters::invoke_status` invokes a static callback returning
`status, payload`; `invoke_handled` accepts `handled, status, payload` and leaves
an empty response untouched when `handled` is false. `invoke_admin` preserves
the six-argument request/method/path/status/body/request-ID output convention.
`payload` and `admin_payload` pass status, metadata and body through the normal
`Response` API. The application deliberately selects omitted Content-Type for
plain MCP errors; binary export and redirects use ordinary response helpers.
No adapter accepts a preformatted HTTP response or bypasses Silly framing.

[snapshot.goose](../examples/promptnook_contract/snapshot.goose) makes an explicit
owned compatibility copy for synchronous raw-request consumers. It retains the
method/target, header spelling/order/duplicates and retained wire whitespace,
then copies the already decoded body. It removes old Content-Length,
Transfer-Encoding, Trailer and Expect fields and writes one decoded-body
Content-Length. The result is a validated HTTP/1.1 request, not the original wire
image: chunk extensions, trailers and the original version/framing are absent.
The caller supplies a fully buffered validated request with Host. Streamed or
failed bodies are rejected; snapshots and borrowed slices must not escape a
synchronous call without separate ownership. Total copy cap is 128 KiB and input headers are capped at 128 (up to 129
after the replacement length field). Parser head/section/line limits still apply.
An error clears partial bytes. Legacy callbacks may allocate their own results;
they remain responsible for bounding that work before handing bytes to Silly.
This optional copy is application-local; normal handlers use borrowed request
views directly. [Adapter/snapshot tests](../tests/integration/promptnook/promptnook_adapters_test.goose)
exercise raw and trimmed headers, missing versus empty fields, duplicate fields,
binary decoded bodies, invalid inputs and limits.

### Compatibility and verified framework gates

- **E10.S2 complete locally:** API/native, combined Portal file/proxy and general-web
  suites pass debug and optimized builds on macOS. A held native DB sequence and
  concurrent real Portal file/proxy requests prove independent I/O in one process.
  Rejection, upstream failure, cancellation, resource drain and lifecycle assertions
  pass. [Migration notes](migration_notes.md) supply exact old/new behavior and port actions.
- **E10.S3 complete:** deterministic Goose tooling, documented external consumer builds,
  all reference applications and matching plan snippets, canonical style checks, and
  macOS/Linux debug/optimized verification pass. The new E10.S3 Linux results below
  are separate evidence; E10.S1's historical local results were not Linux runs.
- **Later application port:** retain the actual domain modules, native dependencies,
  credentials, configuration and migrations. The fixtures do not query a database,
  call identity providers or validate production business behavior.
- **Source identity:** the E1.S1 manifest remains the frozen baseline. Route source
  is reread for E10.S1; correcting an earlier illustrative test path does not
  silently update baseline hashes or modify the PromptNook checkout.

### E10.S1 local verification

Run route and adapter executables from the repository root so the route test can
read `tests/fixtures/promptnook_contracts.json`. Both suites are built with
`goose build <test.goose> --offline -O0 --debug -o <binary>` and again with `-O2`.
The manifest is checked field-for-field against compiled route declarations;
each declaration is dispatched and its response and raw captures are asserted.

`reference/promptnook.goose` builds in both modes and binds an ephemeral loopback
port when run. Local HTTP checks exercised health, domain routes, raw captures,
query-only Admin input, OPTIONS, scoped fallback and oversized capture/query
rejection. SIGINT completed normal lifecycle shutdown with exit status zero.
These checks used deterministic fixtures on macOS, with no production listener,
PromptNook database, configured upstream or credential access.


## E10.S2 cross-component evidence

The [migration matrix](migration_notes.md) records audited old/new behavior,
protocol/resource rationale, targeted tests and the later port action for each
change. It additionally closes differences discovered while reviewing the actual
source: numeric duplicate Content-Length, singleton-header rejection, range/If-Range
policy, static URL decoding/symlinks/list ordering, compression negotiation, selected
representation validators, connection framing, deadlines and bounded audit retention.
Historical Crystal parity prose is supporting context, not a new business parity run.

| Integrated executable | Public composition and assertions | Requirement join |
| --- | --- | --- |
| [API/native/listener integration](../tests/integration/promptnook/promptnook_integration_test.goose) | Real API/Portal listener identities cross owned executor messages; CORS, auth rejection, fixed request IDs, admin metadata, redirect and opaque binary ZIP share normal response framing. A gated native sequence blocks its one serialized lane while both listener health routes remain serviceable. A 196608-byte chunked inline body succeeds; a 65537-byte native handoff and 262145-byte HTTP declaration reject with 413. Active native disconnect yields cancellation and close-once cleanup; subsequent native work succeeds. | R01–R05, R13; H02–H06, H08–H12, H19 |
| [Portal file/proxy integration](../tests/integration/promptnook/promptnook_portal_integration_test.goose) | One stream-capable Portal instance combines rooted static files and the consumer proxy with a disposable local upstream. The same-process API runtime holds a gated native DB call while real Portal file/proxy requests complete. Static and proxy work retain independent ownership; policy/upstream errors, body limits, cancellation and executor/client shutdown are asserted. | R12/R15; H13–H18 |
| [General web integration](../tests/integration/general_web/general_web_test.goose) | One public server combines escaped HTML, form/JSON input and validation, file download, streamed upload/download and SSE. Rejection, oversize input, malformed upload, event limits and disconnect release retained stream resources; handler/transfer/stop counts are checked. | H02/H04/H08/H10/H13/H20 |

The [181-declaration route suite](../tests/integration/promptnook/promptnook_routes_test.goose) and
[legacy adapter suite](../tests/integration/promptnook/promptnook_adapters_test.goose) remain the family
and calling-boundary evidence for R02–R14. Other rows retain the targeted tests in
the ledger above, including local HTTP/HTTPS outbound, rooted file/range and native
interleaving detector tests. The integrated examples intentionally keep deterministic
payloads and request IDs; they do not silently normalize domain behavior.

The runtime's serialized request/response copies each have a 64 KiB body hard cap distinct
from the configurable HTTP body cap. The integrated large-body case deliberately
proves both the larger inline path and explicit native handoff rejection. A later
application port must choose a bounded design for larger native requests, not
assume that increasing the HTTP limit also grows work messages. Streamed admission
uses `RouteOptions.body_bytes_max`; `Limits.body_bytes_max`
controls buffered body storage and must not be mistaken for the streamed route cap.
Streamed Portal operations run in their own public typed server instance alongside
the buffered API/native runtime; no unimplemented runtime-stream API is assumed.

Local verification: all three integrated executables pass debug (`-O0 --debug`)
and optimized (`-O2`) builds on macOS. The disposable HTTP/HTTPS Portal/MCP runner
also passes both modes using fresh native caches. All 24 targeted component suites
selected from the coverage ledger pass in both modes, including core import, HTTP
framing/body/persistence, headers, queries, JSON, CORS, lifecycle, native ownership,
shutdown, files/ranges/static Portal, all routes and legacy adapters.
E10.S3 below adds final deterministic tooling and macOS/Linux verification.
These fixtures use only ephemeral loopback ports,
local temporary files, inert native state and test-owned upstreams.

## E10.S3 package and documentation evidence

The [README](../README.md) documents core and optional client dependencies, an
external core consumer, and an external Portal/client consumer with the current
compiler's explicit native sidecar requirement. The README core snippet was built
outside this checkout in debug and optimized modes. Public lifecycle, routing,
typed state, response commitment and limits are documented in
[handlers](handlers.md); ownership, input/output streams, SSE, files and proxy
composition are documented in [streaming](streaming.md).

All seven `reference/*.goose` files build in debug and optimized modes.
`responses.goose` is now a complete routed executable, not uncalled helper fragments.
`dispatch_proof.goose` remains a narrow language proof rather than a server.
The ten Goose reference blocks embedded in the supplied plan were replaced from
these exact source files and rerendered through `matcha plan`. A `matcha plan read`
comparison confirmed all text outside those blocks unchanged, preserving story IDs,
requirements, order and original design metadata. Historical "proposed" prose in
that frozen plan is not the status of the shipped implementation.

The [Goose verification runner](../scripts/check.goose) and
[suite entry point](../tests/all.goose) implement group/mode selection, per-check
logs and failure exit status. Reference checks include consumers copied outside the
checkout; compiler checks include negative lifetime/static dispatch fixtures and
targeted stack/BCE evidence. No new shell automation, benchmark, metrics, rollout,
publication or production migration is part of this work.

The tested distribution is Goose v2026.3, runtime `4d3da949e563` on both platforms.
macOS uses Apple Clang 17, libcurl 8.7.1 and zlib 1.2.12. The Linux verification
container is Ubuntu 24.04 x86_64 (emulated by Docker Desktop on the arm64 host), GCC
13.3.0, libcurl 8.5.0 and zlib 1.3. These are observed toolchains, not asserted minimum
versions. Linux functional suites ran as unprivileged UID 1000 so deliberately
unreadable-file fixtures enforce their permission contract; running those fixtures
as root is not equivalent verification.

### Final grouped verification results

All listed groups pass on both platforms. Counts are runner check steps, except the
functional row, which names the executable inventory; build and run are separate
steps. Each mode uses its own native cache.

| Group | macOS arm64 | Linux x86_64 | Evidence |
| --- | --- | --- | --- |
| Functional | 127 executables, debug and optimized; no failures | 127 executables, debug and optimized; 509 checks, no failures | Real HTTP/body/routing/lifecycle/stream/file/native and integrated consumer suites |
| Compiler | 133 checks, no failures | 133 checks, no failures | Rejection inventory, negative lifetime cases, static dispatch, targeted stack/BCE logs |
| References | 31 checks, no failures | 31 checks, no failures | All references/examples and external core/Portal consumers in both modes |
| External | 27 checks, no failures | 27 checks, no failures | Disposable HTTP/HTTPS client/proxy fixtures and native file checks in both modes |
| Style | 7 checks, no failures | 7 checks, no failures | Canonical formatter batches and narrowly scoped writable-FFI configuration |

The final macOS functional debug run reports 255 passing steps. Its optimized run
covers the same 127-executable inventory; focused debug/optimized process-adapter
checks also cover the final checker changes. The Linux functional run reports 509
passing steps for both modes together. This records the actual grouped runs rather
than inventing a single all-groups invocation. The runner writes per-check logs under its selected output directory and returns
nonzero on any failure. Linux logs and generated consumer sources were archived to
`/tmp/silly-e10s3-linux-evidence.tar.gz` on the validation host before removing the
disposable container; macOS logs remain in their selected output directories.

### Targeted compiler evidence

The optimized `compiler` group records `--stacks --bce-lines` output for these
consumers. macOS results with runtime `4d3da949e563` are shown as elided/total checks:

| Target | Index checks | Slice checks |
| --- | --- | --- |
| `examples/hello.goose` | 98/142 | 12/89 |
| `tests/routing/route_plan_test.goose` | 32/52 | 8/27 |
| `tests/http/http_head_test.goose` | 61/84 | 9/37 |
| `tests/streaming/stream_http_test.goose` | 140/242 | 35/164 |
| `tests/integration/general_web/general_web_test.goose` | 224/423 | 75/250 |

Checks that remain are intentional runtime bounds checks, not a failed claim that
all indexing is unchecked. Stack reports describe compiler-managed virtual regions
(2 GB reserved per stack, 1 MB guard gap, 32 TB region budget, `GS_MAX_STACKS 1024`),
not resident allocation per handler. Per-function own/callee data-stack counts and
individual BCE source lines remain in each `analysis-*.log` under the selected output
directory. These diagnostics are verification evidence, not performance benchmarks.

The final boundary remains the [later PromptNook port](migration_notes.md#concrete-entry-point-mapping-for-the-later-port):
retain its real domain/native/configuration code, adapt its explicit calling
boundaries, choose finite resource policies and serialized native ownership, and
wire application lifecycle/audit behavior. Framework verification does not execute
that port or deploy/publish anything.
