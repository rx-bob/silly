# E4.S1 indexed request headers

The head parser now builds a bounded name index while collecting fields. The overload
`parse_head(input, fields, index, limits)` requires empty field/index owners. Both remain
empty on incomplete or rejected input; partial collection is cleared if framing fails.
The original overload remains available. The server uses the indexed overload and
retains both owners through the handler's final use.

Each `HeaderIndexEntry` contains a wire-order field index and `source: HeaderField`
with name/value offsets and lengths relative to the beginning of the supplied head.
Offsets cover original spelling and exact bytes after the colon, including SP/HTAB.
The source bytes and ordered HeaderView array are never rewritten. Sorted index entries
compare ASCII-case-insensitive names, with wire order breaking ties. Header-count and
byte limits bound construction. Insertion is quadratic in field count in the worst case;
lookup uses binary name bounds, and iteration visits only that name's indexed entries.
No operation rescans the entire raw request or allocates a result buffer per lookup.

`Request.header_index` borrows this metadata. Hand-built requests that omit it continue
to scan their bounded HeaderView array; they do not need to reconstruct raw HTTP. A
nonempty index must come from the same parsed fields and must remain unchanged. Public
struct fields are driver metadata; constructing an inconsistent index bypasses the API
contract, just as mutating other driver-owned offsets does.

| Operation | Result |
| --- | --- |
| `header(request_or_ctx, name)` | First value, leading and trailing SP/HTAB removed |
| `header_raw(request_or_ctx, name)` | First value, leading SP/HTAB removed, trailing retained |
| `header_wire(request_or_ctx, name)` | First exact value, all SP/HTAB retained |
| `header_values(request_or_ctx, name, mode)` | Cursor over every occurrence in wire order |
| `next_header(cursor)` | Next FieldValue; absent after exhaustion, including repeated calls |

`HeaderValueMode` is Trimmed (default), Raw or Wire. All names match case-insensitively.
`FieldValue.present` is independent of length. Empty and whitespace-only fields both
produce an empty trimmed/raw value, but exact Wire values distinguish them. No helper
splits commas, joins duplicates or drops empty occurrences. `Request.headers` retains
all original names/values for enumeration. Context and Request also support method-call
syntax such as `ctx.header_raw("Authorization")` and `request.header_values("X-Tag")`.

```text
var values = silly::header_values(ctx, "X-Tag", silly::HeaderValueMode.Wire);
while true {
    let field = silly::next_header(values);
    if !field.present {
        break;
    }
    // Consume field.value, including empty values, before resetting request storage.
}
```

Core/users authentication in the audited PromptNook source uses a leading-trim-only
Authorization value and a case-sensitive `Bearer ` prefix. Missing, empty, whitespace-
only and wrong-scheme values select its missing/invalid-header error. `Bearer ` with an
empty suffix still selects its invalid/expired-token error. A trailing token space is
retained for session lookup. Admin instead fully trims the header and then trims its
token. Fixtures reproduce these extraction/error distinctions without adding an auth
policy, database lookup or trust decision to Silly.

Authorization, Proxy-Authorization, Host and Content-Type remain parser-enforced
singletons; duplicates fail before dispatch. Repeatable metadata retains all values.
Content-Length and Transfer-Encoding have separate strict framing policies documented
in [HTTP heads](http_heads.md). The access helpers do not relax parser decisions.
X-Mcp-User-Id, X-Zitadel-User-Id and X-Forwarded-User remain ordinary untrusted bytes:
precedence, verification and identity interpretation belong to the application.

Requests, exact/trimmed values and cursors borrow retained driver-owned input/metadata.
Keep head, field/index arrays and any borrowed lookup name alive until their final use.
End these borrows before clearing or reusing owners for another request. Grow-only
storage append does not invalidate existing bytes, but shrinking/resetting does. Do not
retain a request cursor in a queued proxy/async operation; copy needed values into that
operation's bounded owner during preparation. Compiler rejection fixtures cover reset
while values/cursors still live; positive fixtures reset and parse a fresh request after
last use. Persistence scheduling itself remains E2.S4 work.

Next in the plan: **E2.S2 — Support fixed-length and chunked request bodies with bounded readers**.

Optimized indexed-header fixture diagnostics retain bounds checks where needed: 64/93
index checks and 10/53 slice checks are eliminated. The fixture uses three data-stack
regions (default 2 GiB virtual reservation each, not resident allocation). No unchecked
lookup annotation, hash collision assumption or throughput claim is introduced.

Verified 2026-10-27 with Goose runtime `4d3da949e563`:

- macOS arm64, Apple clang 17: indexed-header, auth-policy and real socket fixtures,
  plus existing header, HTTP-core/head, Request and Context regressions pass optimized
  and debug builds. Three new expected lifetime rejections match in each mode.
- Ubuntu 24.04 x64 under Docker emulation, GCC 13.3: all 28 positive executables pass
  in both modes, including route, transport, ownership and continuation regressions.
  All 12 expected compiler rejections per mode match their specific diagnostics.
- Repository source/reference formatter checks and whitespace checks pass. The existing
  ignored docs/reference policy is unchanged; no consumer code was modified.
