# E2.S1 request heads

`scan_head(scan, input, limits)` takes an append-only cumulative input view and fixed
limits. Keep earlier bytes unchanged. `HeadScan` retains offsets and scalar state only;
it examines newly appended bytes, validates each completed line, and stops exactly at
the empty CRLF line. Completion and failures are sticky. `finish_head` turns unfinished
input into sticky `Truncated`. Do not reuse a scan across requests without resetting it.

Scanner completion establishes structural syntax. Call `parse_head(input, fields,
limits)` with an empty field owner to validate Host, singleton fields and framing before
dispatch. It returns borrowed method/target/authority and ordered raw header views only
after validation, plus `head_bytes`, HTTP minor version and `BodyFraming`. It clears
partially collected fields on failure. Retain the input owner through every view use.
The bounded complete-head pass is linear; it does not collect or consume bodies.
Bytes at `input[head_bytes..]` remain untouched for body/persistence work.

Methods use token grammar. Request lines require exact single-space separators and
HTTP/1.0 or HTTP/1.1. Origin, absolute HTTP(S), CONNECT authority with port, and OPTIONS
asterisk forms are validated. Absolute schemes are case-insensitive. Targets remain raw;
query percent-decoding and invalid-escape policy belong to E4. URI controls, fragment
markers and illegal raw characters are rejected, with bracketed IP literals allowed in
authority only. Header names use token grammar; whitespace before colon, folding, bare
LF, invalid CRLF and controls other than value HTAB are rejected.

HTTP/1.1 requires exactly one nonempty valid Host. HTTP/1.0 may omit it. Present Host
must be a valid reg-name or bracketed IPv6/IPvFuture authority with an optional numeric
port in 0..65535. Duplicate Host, Authorization, Proxy-Authorization and Content-Type
are rejected. Other duplicate fields retain original ordering, case and value whitespace.

Framing policy:

- Content-Length accepts decimal digits only, up to signed 64-bit maximum. Identical
  numeric values in repeated or comma-list fields are accepted, including leading zeros.
  Empty, signed, overflowing or conflicting values fail with 400.
- Content-Length plus Transfer-Encoding always fails with 400.
- Transfer-Encoding is HTTP/1.1 only. The supported coding list is exactly `chunked`.
  Repeated/nonfinal chunked, no final chunked, empty items and parameters fail with 400.
  Other token codings preceding final chunked are unsupported (501).
- No framing field means no request body. Positive fixed length and chunked framing are
  reported by the parser; body consumption belongs to E2.S2.

These decisions follow RFC 9112 section 6.3 and RFC 9110 section 8.6, with a deliberately
restricted transfer-coding grammar. Raw fields are never rewritten by framing validation.

| Limit | Default | Accounting |
| --- | --- | --- |
| request_line_bytes_max | 8192 | Includes line CRLF |
| header_line_bytes_max | 16384 | Includes line CRLF |
| header_section_bytes_max | 16384 | All fields and final empty CRLF |
| head_bytes_max | 32768 | Request line and entire header section |
| header_count_max | 100 | Field lines |
| header_bytes_max | 32768 | Sum of raw names and values, excluding colons/CRLF |

Wire limits must be positive and are independent. Count/name-value limits may be zero.
Exact boundaries are accepted when the complete line/head fits. Larger request lines
map to 414; header/head/count limits map to 431. Syntax, Host and framing failures map
to 400; unsupported syntactically valid HTTP versions map to 505.

The close-only server now validates body framing and collects accepted bodies through
[E2.S2's bounded reader](request_bodies.md). Handler dispatch occurs only after completion.
Malformed heads and rejected bodies never dispatch trailing bytes. Bounded error responses
use Connection: close; partial EOF closes deliberately. Closing with unread bytes can reset
TCP and truncate the attempted error reply. Valid responses require complete draining.

`parse_get_head` remains the old exact-head/bodyless-GET adapter. Unlike `parse_head`,
it rejects trailing bytes and reports incomplete input as BadRequest. Signed lengths
and malformed targets formerly tolerated by that adapter are now rejected.

Verification fixtures cover every two-piece split and bytewise delivery, all target
forms, raw duplicates, framing ambiguity, Host literals, sticky failures, EOF, poisoning,
and exact limits including 8 KiB/16 KiB defaults. Socket tests force seven-byte I/O turns
and prove invalid requests never dispatch while valid requests before/after still work.
`goose check tests/http/http_head_test.goose -O2 --stacks --bce-lines` reports two data-stack
regions, 54/68 index and 10/38 slice checks eliminated. Remaining parser checks are kept;
there is no checkfree annotation or throughput claim. Stack reservations are virtual.

Next in the plan: E3.S1, prepare immutable route data and static handler dispatch.

Verified 2026-10-27 with Goose runtime `4d3da949e563`: macOS arm64 release/debug
passes the new parser, invalid-input, limits, Host and socket fixtures plus affected
HTTP core, server-state, request, context and static API regressions. Ubuntu 24.04 x64
(GCC 13.3, Docker emulation) passes all 19 positive fixtures in both modes, plus seven
expected lifetime/compiler rejections per mode with matched diagnostics. Formatting
and whitespace checks pass. Documentation remains in the repository's ignored docs tree.

E4.S1 extends `parse_head` with a caller-owned `HeaderIndexEntry` array. Collection
builds sorted name metadata and retains source offsets without changing raw fields.
Both output owners clear on rejection. The production server retains this index through
handler use; see [indexed header access](request_headers.md).
