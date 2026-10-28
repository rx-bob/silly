# E2.S2 bounded request bodies

`new_body_reader(framing, length, BodyLimits)` creates fixed-size state with no retained
input/output references. `read_body(reader, input, output, work_limit)` returns consumed
wire bytes, produced decoded bytes and BodyStatus. Resume with the unconsumed suffix and
fresh output capacity. Complete stops exactly after Content-Length bytes or the final
chunk/trailer terminator; trailing bytes remain caller-owned and untouched.

NeedInput waits for more bytes; NeedOutput waits for output capacity; Progress yields
when the per-call work budget is exhausted. Complete and all failures are sticky.
`finish_body` turns an unfinished reader into Truncated at EOF. BadFraming, Truncated,
Limit, OverheadLimit and InvalidLimits are distinct. A zero/negative work budget is an
invalid configuration for an active reader. No-progress calls do not spin internally.

`collect_body(reader, input, output_owner, cap, work_limit)` appends bounded decoded
chunks using an 8 KiB scratch buffer. Call repeatedly until Complete or failure. The cap
can tighten the reader's decoded limit; it cannot relax it. Partial bytes may exist after
failure and must not be treated as a valid body. For streaming consumption, call read_body
with bounded output slices and consume each chunk before its next reuse. Neither helper
imposes a 128 KiB body ceiling. `examples/body_reader.goose` demonstrates binary data,
small output buffers and retained bytes belonging to the next request.

Framing.None and Fixed with length zero are both immediately complete but remain distinct
in `reader.framing`. Chunked empty requires a zero-size chunk and final empty trailer
line. The server exposes the same distinction as `Request.body_framing`; `body_view`
returns the exact decoded bytes only after completion. Empty POST is valid. A body is
never inferred from the method, and premature EOF never dispatches an incomplete body.
JSON bytes receive no transcoding, trimming, decoding or newline changes.

| BodyLimits field | Default | Accounting |
| --- | --- | --- |
| bytes_max | 8 MiB | Decoded body bytes |
| overhead_bytes_max | 1 MiB | Chunk sizes/extensions, CRLF separators and all trailers |
| line_bytes_max | 8192 | Each metadata line including CRLF; positive and at most 8192 |
| trailer_bytes_max | 16384 | Trailer section including its final empty CRLF |
| trailer_count_max | 100 | Nonempty trailer fields |
| chunk_count_max | 65536 | All chunk-size lines, including the final zero chunk |

Other caps may be zero. The line ceiling matches the reader's fixed inline storage;
it is a metadata ceiling, not a payload ceiling. Chunk sizes use overflow-checked hex.
Extensions allow token names, optional token/quoted-string values, quoted escapes and
HTTP bad-whitespace positions. Invalid delimiters, bare LF, controls, missing CRLF,
malformed trailers and missing terminal chunks fail explicitly. Trailer names/values
use header grammar. Framing, routing, authentication and selected representation fields
are rejected as trailers (the exact list is in chunk_decoder.goose). All accepted trailer
metadata is discarded, never merged into request headers. Only one framing layer is
supported; transfer/content decompression and recursive framing are not implemented.

Input-byte work per read call is bounded independently of total body/framing caps.
Completing a metadata line adds one parse bounded by line_bytes_max; collection has its
fixed scratch cost. Server inactivity uses the existing monotonic idle timeout and real
I/O progress. No nested parser or unbounded metadata recursion exists.

The server retains separate head, decoded-request, response-head, response-output and
socket-staging slabs. `ServerOptions.body_read_bytes_max` defaults to 16384 and is also
capped by work_bytes_per_turn. Startup budget arithmetic includes every byte slab before
allocation. The default slab budget rises from 256 to 512 MiB so the default 16 connections
can retain both 8 MiB request and output bodies. It is a cap, not an eager 512 MiB allocation;
the slabs themselves are eagerly initialized. Fixed decoder/descriptor metadata remains
outside that byte-slab budget, as existing connection metadata did.

The effective decoded cap is the minimum of `Limits.body_bytes_max`,
`ServerOptions.body_limits.bytes_max` and any nonnegative `RouteOptions.body_bytes_max`.
The route default -1 inherits server limits; lower negative values fail preparation.
Known fixed-length overflow fails before reading the body. Chunked overflow fails when
the size would exceed the decoded cap. Limit/overhead violations return 413; malformed
framing returns 400. EOF/inactivity closes deliberately without handler invocation.

Expect is handled after strict head/framing validation, route admission and cap checks.
Supported expectation is case-insensitive 100-continue; unsupported expectation values
return 417. HTTP/1.1 sends a bounded interim 100 before awaiting an accepted non-complete
body; HTTP/1.0 ignores 100-continue. Route/cap rejection sends a final response instead.
Interim writes can fragment and resume through the normal nonblocking scheduler.

Early responses use Connection: close and do not drain rejected input. Closing with unread
bytes can cause a TCP reset and truncate the attempted final error response. Valid replies
still require complete framing. The low-level reader preserves unread next-request bytes;
the current server remains close-only and does not dispatch pipelined tails. Persistence
is E2.S4. Application stream_input callbacks and streamed routes remain E7 integration;
this story provides the bounded pull primitive and collected-body server path.

Protocol basis: [RFC 9112 chunked coding](https://www.rfc-editor.org/rfc/rfc9112.html#section-7.1)
and [RFC 9110 Expect](https://www.rfc-editor.org/rfc/rfc9110.html#section-10.1.1).

Next in the plan: E2.S3 — Serialize protocol-correct responses without joining headers and bodies.

Optimized body fixture diagnostics report seven data-stack regions (default 2 GiB virtual
reservation each, not resident allocation), with 11/31 index and 6/25 slice checks
eliminated. Remaining bounds checks are retained; no new checkfree annotation is used.

Verification on 2026-10-27 with Goose runtime `4d3da949e563`:

- macOS arm64, Apple clang 17: all three pure body suites, real body socket fixture,
  bounded-reader example, routed-server/state regressions and route-cap validation pass
  optimized/debug builds. Interim socket writes are also forced into seven-byte pieces.
- Ubuntu 24.04 x64 under Docker emulation, GCC 13.3: 33 positive executables pass per mode,
  including body/socket, head/header, route, transport, ownership and continuation suites.
  Twelve expected compiler rejections per mode match their specific diagnostics.
- Large-body fixtures verify all 262,145 payload bytes for fixed and chunked framing,
  including zeros. Socket checks cover empty bodies, early admission, partial interim
  writes, malformed/unfinished input, inactivity and exact handler counts.
- Formatting and whitespace checks pass. Existing ignored docs/reference directories
  retain that status; consumer code remains untouched.
