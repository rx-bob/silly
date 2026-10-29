# URL, query and form decoding

These operations decode bytes once. They do not normalize paths, validate UTF-8,
interpret application IDs, authenticate tokens or build proxy URLs. NUL and non-UTF-8
bytes remain observable in returned slices. Filesystem path validation must independently
reject unsafe decoded paths; query compatibility policy never changes `decode_path`.

## Raw and decoded query access

`raw_query(target)` returns `FieldValue`, distinguishing no `?` from a present empty
query. Targets supplied by the server already passed HTTP validation. Low-level raw
query functions take query bytes without `?`, not a complete URL.

`raw_query_pairs(raw, options)` returns a bounded iterator. `next_raw_query(iterator)`
returns `{ present, pair, error }`. Pairs retain key/value bytes and `has_equals`.
An empty input has zero pairs; `&` has two empty pairs, and `a&` retains its trailing
empty pair. Only the first equals sign separates key from value. Raw iteration never
validates percent escapes. Errors are sticky, distinguishable from ordinary exhaustion.
`raw_key_present(raw, name, options)` compares original key bytes and returns
`{ present, error }`; it scans through the cap checks rather than silently accepting a
matching prefix of an over-limit query.

`parse_query(raw, scratch, options)` is an ordinary local error-return operation. Its
`QueryPairs` result owns a bounded metadata list in `entries` and reports `QueryError`.
Each `QueryPair` exposes decoded `key` and `value`, unchanged `raw_key` and `raw_value`,
and `has_equals`. Ordered repetitions and empty entries survive decoding.
`get(pairs, name)` returns the first decoded-key match as a `FieldValue`.
`query_values(pairs, name)` and `next_query_value(values)` enumerate all matching values
in input order. Missing keys, a bare key, and an empty assigned value remain distinct
through presence and `has_equals`.

`query_pairs(ctx, scratch, options)` returns a fixed-size borrowed `QueryView`;
`query(ctx, name, scratch, options)` returns a fixed-size `FieldValue`. Both run inside
an endpoint. A view exposes `count`; `query_iterator(view)` and `next_query_pair(iterator)`
provide decoded ordered pairs, and the same get/all-values/filter operations accept it.
`parse_query_view(raw, scratch, options)` is the local-error counterpart. They reject malformed input through its named guard boundary, so later
handler statements do not execute. The first-value helper resolves its view directly
from input/scratch rather than returning a view of temporary pair metadata. Strict
lookup validates the entire query, including fields after the requested key.
`query_literal_invalid_escape(ctx, name, scratch, options)` is the narrowly named
compatibility operation for malformed percent escapes. Explicit
`QueryOptions.invalid_escape = InvalidEscape.Literal` also enables that behavior for
pair iteration. Ordinary defaults are strict.

Query decoding maps `+` to space; `%2B` becomes literal plus. Valid percent triplets
produce one byte; `%252F` becomes `%2F`, not slash. Literal-invalid mode copies a malformed
percent byte and continues processing later bytes, so `%GG%41+%` becomes `%GGA %`.
It does not weaken the strict path or form wrappers.

`QueryOptions.separators` accepts `"&"` (default) or the deliberate Portal-compatible
`"&;"`. Encoded delimiters such as `%26`, `%3B` and `%3D` stay inside their original
field after decoding. `without_query_keys(pairs, keys, KeyMatch.Exact)` returns a fresh
bounded metadata collection retaining the byte views; `AsciiIgnoreCase` provides
explicit ASCII-insensitive decoded-key filtering. Filtering never reorders, groups,
re-encodes or deduplicates the remaining fields. Bind filter keys to a named local
list and keep it in scope with the filtered result; the pinned compiler conservatively
tracks that borrowed key-list lifetime for view filtering. Portal URL rewriting and environment
selection remain application-owned.

## Ownership and budgets

Unchanged fields borrow raw input and append nothing to scratch. Transformed fields
borrow caller-owned scratch. Parsing preflights the entire input before metadata
allocation or scratch growth: input length, every pair (including empty pairs), strict
escapes and the aggregate decoded key/value byte count. Only then does it append all
transformed fields and bind views. On error, scratch remains unchanged and no partial
pair collection is returned. Existing scratch prefixes are preserved.

Both `QueryOptions` and `FormOptions` default to `input_bytes_max = 65536`,
`pairs_max = 1024`, `decoded_bytes_max = 65536`. Negative caps are invalid. Zero caps
permit empty input; nonempty input must satisfy every applicable cap. Decoded-size
accounting includes borrowed fields too, excludes separator/equals syntax, and separately
bounds the final scratch length including its existing prefix. The server's head/body
caps apply before these decoder budgets. Filtering cannot exceed its source pair cap.

Keep input, owned metadata (when used) and scratch alive while their dependent views/iterators are used;
do not grow/reset owners during those borrows. Compiler-negative fixtures verify raw
input and decoded scratch reset rejection. A filtered collection is not a deep byte copy.

Local parsing returns explicit errors. Endpoint query helpers produce 414 for input
length, 400 for malformed escapes/pair/decoded limits, and 500 for invalid configuration,
with a bounded text rejection. Applications needing custom envelopes can call the local
operations and prepare their own response before `reject(ctx)`.

## URL-encoded forms

`parse_form(request, scratch, options)` returns a fixed-size `Form { error, pairs }`
whose pairs field is a borrowed `QueryView`, without a guard.
`require_form(ctx, scratch, options)` (also `ctx.require_form`) rejects failures through
the endpoint boundary. `form.get(name)` returns the first value; `form_values(form, name)`
uses the same repeated-value iterator. Body extraction is independent of HTTP method.

Forms require exactly one Content-Type with case-insensitive
`application/x-www-form-urlencoded`. The only optional parameter is one `charset=utf-8`
(quoted or unquoted, case-insensitive, with surrounding whitespace accepted). Other or
duplicate parameters, duplicate Content-Type fields, missing media type and unsupported
charset yield 415. The charset label does not trigger transcoding or UTF-8 validation.
Forms always use strict escapes, plus-as-space and ampersand separators. There is no
permissive form policy; semicolons remain field data.

Endpoint form errors yield 400 for malformed encoding/unavailable buffered body,
413 for pair/input/decoded limits, 415 for media policy, or 500 for invalid options.
The raw body remains available unchanged. Server body admission still enforces its own
cap before collection and before 100 Continue.

`examples/form.goose` serves a real HTML form on port 8082. Submission decodes a name,
copies it into bounded application state and prepares a 303 Location `/thanks` response.
The socket test runs the same handlers and verifies the redirected response, malformed
input, media policy, decoder limits and body rejection before 100 Continue. Response
convenience redirects remain E5.S1; the example uses existing checked response operations.

## Consumer evidence and verification

`tests/request/query_compat_test.goose` derives fixtures from retained PromptNook source:
`backend/goose/http_posix.c:893` (`pn_query_value`), `:947` (`pn_query_has`),
`admin/raw_prefix_scans.goose:347,368`, and `portal/portal.goose:216`.
Decoded `%65nvironment` lookup and raw `environment` presence intentionally differ;
bare/empty/space-valued cursor and limit remain observable. Token plus/percent,
email, binary ID and first-repeat behavior are preserved. Generic iteration retains
ordered empty pairs even where consumer-specific proxy rewriting skips/groups them.

URL, query, compatibility, capacity, endpoint and form fixtures cover strict/literal
escapes, UTF-8 bytes, binary NUL, encoded separators, one-pass path decoding, raw and
transformed borrows, exact/exceeded caps, filtering and real form redirects.

Next story: **E4.S3 — Provide composable JSON writers and optional typed binding**.


Verification on macOS arm64: debug/release URL, query, endpoint, source-compatibility,
capacity and form tests pass, along with existing capture/endpoint regressions. All three
new lifetime negatives reject with the expected owner-reset diagnostics. Formatting and
whitespace checks pass. Linux has not been rerun; Docker startup was blocked in the
preceding validation attempts. Full rerun script: `/tmp/silly-e4s2-linux/run.sh`.


### Guard return representation

Socket testing exposed a pinned-compiler unwind defect when a nonlocal guard exits a
function returning a growable owner before its result is initialized: generated caller
cleanup reads the uninitialized result's stack base. Guarded extractors therefore return
fixed-size borrowed views, never growable owners. Ordinary `parse_query` and filtering
can return owned metadata because they have no nonlocal exits. This separates error
control flow from allocation ownership and preserves the scratch-only endpoint API.
Repeated malformed-form/query requests followed by valid requests test retained route
storage across guard exits; a single isolated rejection is insufficient for this edge.
