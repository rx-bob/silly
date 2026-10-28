# Rooted files and owned file responses

Configure a file root during startup with `open_file_root(path)`, then start a bounded
`FileExecutor` using `start_file_executor`. The executor has 1–4 workers, 1–64 admitted
file slots, and a configured read chunk of 1–4096 bytes. Each slot reserves one native
completion buffer, so a slow client cannot create an unbounded completion queue.

`open_file(executor, root, relative_encoded_path)` admits an asynchronous open job.
Success means admission, not filesystem success. The worker opens and validates the
file; `file_status` reports pending, open, chunk, end or failure with an OS error.
Request-time path walks, file metadata and reads execute on these dedicated filesystem
workers. The existing endpoint executor returns complete response snapshots; this
specialized bounded file executor instead owns incremental jobs and descriptors.

## Path policy

Paths are root-relative URL-path bytes. Percent decoding occurs exactly once, `+`
remains literal, and encoded slash/backslash are rejected. Reject absolute paths,
NUL, backslash, malformed escapes, empty components, `.` and `..` components. Decode
before component validation. A second level of escaping names literal percent bytes;
it never triggers another decode.

The configured root must end in a real directory, not a symlink; its configured
ancestor path is trusted startup configuration. All symlinks beneath that root are
denied. Root opening and component walking use directory descriptors;
intermediate opens require directories and reject symlinks. The final descriptor is
checked as a regular file. No realpath-prefix comparison or separate check-then-open
sequence authorizes access. A pinned root descriptor defines the authority: replacing
a path after opening does not replace the validated inode. Root configuration and
filesystem namespace administration remain trusted application responsibilities.

## Serving and ownership

Use `Context<App, FileTransfer>` with the normal six-argument streaming `serve` and
`file_step` as its static producer callback. `file_response(ctx, owned_file, FileOptions)`
checks/copies metadata and transfers the handle only on success, clearing the caller's
`OwnedFile`. If selection fails, the caller must close that handle with `close_file`.

`FileOptions` carries offset, length (`-1` means the remaining opened file), content type,
optional attachment filename, pending chunk capacity, and finite polling interval.
Offset/length arithmetic is validated against metadata from the opened descriptor.
These are transfer bounds. `static_file_response` adds HTTP Range negotiation as described below.
HTTP framing uses the existing stream writer.

Only one file read is outstanding per transfer. The producer polls its token using
`Wake.After`, copies a completed native chunk into retained stream storage, and waits
for transport acknowledgement before requesting another read. Short reads advance
exactly their returned count. EOF before the promised range finishes is a transfer
error; appended data beyond the opened size is not implicitly included. Concurrent
in-place file modification is not a snapshot guarantee.

Normal completion and Cancelled both release the file token once. Worker ownership
outlives a pending syscall: cancellation marks the slot and its worker closes the
file after the operation returns. Closing a connection never closes/reuses an active
file descriptor from the I/O owner. Epoch/token checks reject stale operations.
Before wire commitment file failures can render an error; after commitment the stream
closes without another response or successful chunk terminator.

`stop_file_executor` closes admission and requests cancellation. Repeated
`finish_file_executor` checks are nonblocking: incomplete retains the executor handle
and all pending resources. Do not discard it or reuse executor state until complete.
An indefinitely blocked filesystem operation retains its resources; it is not killed.
Root descriptors are application-owned; admitted opens pin their own descriptor copy.
Serialize root closure against new admissions; an already admitted open remains valid
after closing the original root. Do not copy a root handle and close both copies.

Generated ZIP bytes can use the existing attachment helper, and a generated archive
file uses `file_response` with `content_type: "application/zip"` and a chosen filename.
Silly never generates or rewrites archive contents.

Verification on macOS: native adversarial and Goose transfer/loopback suites pass debug
and optimized builds. Tests cover bounded short reads/writes, opaque ZIP bytes,
metadata-failure ownership, invalid extents, truncation after commitment, descriptor
pinning, concurrent symlink replacement, trailing-slash root links, and cancellation
while a worker is held inside a read. The existing stream socket suite also passes.


## Static metadata and conditional requests

`static_file_response(ctx, owned_file, path, StaticFileOptions)` selects a full-file
response with descriptor-derived length, Last-Modified and a weak ETag. Without a matching
conditional or accepted range it returns 200. Ownership
transfers only on successful selection, just as with `file_response`. Supply the
resource path for MIME classification: `.html`/`.htm`, `.mjs`/`.js`, `.css`, `.txt` and
`.wasm` map to HTML, JavaScript, CSS, plain text and WebAssembly; unknown suffixes use
`application/octet-stream`. Suffix comparison is ASCII case-insensitive. `content_type`
overrides the mapping. Text types receive `charset=utf-8` by default; an empty
`charset` suppresses it, and another value overrides it.

The file worker captures size, modification seconds/nanoseconds, device and inode
from the same descriptor used for subsequent reads. `file_metadata(owned_file)` reads
that immutable snapshot after open completes. It does not perform filesystem I/O on
the connection owner. The default weak ETag encodes those stat fields; it does not
promise a content hash or protection against concurrent in-place edits.

Set `StaticFileOptions.etag` to a validated entity tag, or supply a static callback:

```goose
fn validator(metadata: FileMetadata) -> FileValidator {
    var result = FileValidator {};
    result.etag.append(str("W/\"portal-", metadata.size, "\""));
    return result;
}

fn step(state: FileTransfer&, event: StreamEvent, out: ChunkWriter&) -> StreamStep {
    return file_step_with_validator(state, event, out, validator);
}
```

Use `step` with the typed streaming serve overload. The hook runs once after the
opened metadata is available and returns owned ETag bytes (up to 256). An explicit
options ETag takes precedence over the callback result. An empty callback ETag omits
ETag; malformed nonempty tags fail before commitment. The hook must be nonblocking.

GET and HEAD evaluate If-None-Match using weak comparison, including tag lists and
`*`. Presence of that header suppresses If-Modified-Since even when malformed or empty.
Without it, a valid HTTP date matches when the opened modification time is no later
than the supplied time. All three HTTP date formats are accepted; malformed dates and
repeated If-Modified-Since fields miss the cache. `conditions: false` disables these
checks. Other methods receive the representation without conditional 304 selection.

Conditional values are copied before request storage is reused: combined If-None-Match
is capped at 4096 bytes, and If-Modified-Since at 128. Oversized values miss the cache
without truncating a value into a possible match. ETag and Last-Modified remain owned
through deferred header preparation. HEAD and 304 use the shared response writer,
carry the full representation Content-Length, and never queue body reads. A full GET streams
exactly the opened size with fixed-length framing; a truncated file fails the transfer.

Each stream slot reserves up to 128 retained response header fields and 16384 header
bytes for deferred preparation; ordinary configured header and wire caps still apply.
The final HTTP head is built only after the metadata callback completes, before any
wire commitment. A pathname replacement after metadata capture cannot switch the file
used for the body.


## Byte ranges and multipart transfers

`StaticFileOptions.ranges` defaults to true. `ranges_max` defaults to 16 and must be
between 1 and 16; invalid configuration fails before taking ownership of the file.
`ranges: false` ignores Range and omits the range-support advertisement. Enabled
responses advertise `Accept-Ranges: bytes`.

Range applies only to GET. HEAD ignores Range and If-Range, returns the full selected
representation metadata (or conditional 304), and never reads or emits body bytes.
If-None-Match/If-Modified-Since are evaluated first; a 304 takes precedence over Range.
A failed If-Range condition returns the complete 200 representation.

`parse_file_ranges(value, size, max_ranges)` returns `RangePlan` with status `Ignore`,
`Satisfiable` or `Unsatisfiable` and up to 16 `ByteRange { offset, length }` entries.
It supports inclusive closed ranges, open-ended ranges and suffix lengths, using
checked signed 64-bit arithmetic. The `bytes` unit is case-insensitive. Ends beyond
EOF are clipped; oversized suffixes select the full file; zero suffixes select no
bytes. Unsatisfiable entries are omitted when another requested range is satisfiable.
Ranges retain request order and overlaps, including duplicate ranges; no coalescing
or reordering occurs. Every parsed entry counts toward the configured limit, even
if it selects no bytes.

Malformed ranges, unsupported units, integer overflow, more than `ranges_max`
entries, repeated Range fields, or a field exceeding 4096 bytes are ignored and
produce the ordinary 200 response. No truncated or partially parsed list is served.
A valid list with no satisfiable ranges, including requests against an empty file,
returns 416 with `Content-Range: bytes */size` and zero Content-Length. A single
selected range returns 206 with `Content-Range: bytes start-end/size` and its exact
Content-Length.

If-Range accepts one strong entity tag or a valid HTTP date. ETags compare exactly,
including case; weak supplied or current ETags never match. The default stat-derived
ETag is weak. Date comparison is exact, unlike If-Modified-Since, and requires the
application validator to set `FileValidator.last_modified_strong: true`. Set this
only when the application can guarantee the representation did not change twice
within the modification second. The default is false; an old timestamp alone does
not establish strength. Malformed, repeated or over-256-byte If-Range fields fail
and therefore select the complete representation. The protocol rules follow
[RFC 9110](https://www.rfc-editor.org/rfc/rfc9110.html#name-if-range).

Multiple selected ranges return `multipart/byteranges` with a fresh 128-bit random
boundary encoded as 32 hexadecimal characters. The outer response replaces the
original Content-Type and has no Content-Range; every part includes the original
Content-Type (including charset) and its own Content-Range. Boundary generation
failure aborts before wire commitment. Content-Length includes every delimiter and
part header, with checked arithmetic before commitment.

The producer retains at most 16 range records and one 768-byte framing segment,
with a 16384-byte total framing-work cap. It emits framing through the same bounded
chunk writer as file bytes and resumes after short writes at any delimiter, header
or file segment. Only one file read is outstanding, and the same validated open
descriptor supplies every range. It never buffers a whole file or multipart body.
Length overflow or excess framing work ignores Range and serves the complete file.
The original Content-Type including charset is bounded to 512 bytes; oversize
configuration fails before file ownership transfer.

These are deliberate corrections to the observed Portal behavior: the media type
is the plural `multipart/byteranges`, replacing `multipart/byterange`, and HEAD emits
no file or range body. The range parser and socket fixtures cover these contracts;
the socket fixture uses small producer and transport budgets to exercise boundaries.


## Precompressed mounts and directory policy

`FileMount` selects static behavior through an ordinary typed catch-all handler:
`static_mount_response(ctx, mount)` retains `StaticTransfer`; `static_file_step`
drives the operation. The mount references an application-owned root and executor.
The [executable Portal reference](../reference/files_and_portal.goose) uses
`DirectoryPolicy.List`, `MissingFilePolicy.RootListing`, and
`gzip_freshness_ms: 10`. These are consumer choices; defaults reject directories and
missing resources. No implicit index.html or SPA rewrite occurs.

All path opens, sibling selection and directory enumeration run on native file
workers. Root/descendant opens reject symbolic links, traversal components and
encoded separators. Listing uses the validated directory descriptor, skips `.` and
`..`, and includes only regular files and directories without following symlinks.
Names are sorted bytewise, escaped as HTML text and percent-encoded as URL path
segments. Directory URLs receive a slash suffix; redirects return 302, insert the
slash before the query, preserve existing escapes, and encode unsafe bytes. HEAD
uses the shared writer and emits no listing or redirect body.

GET/HEAD are supported; other methods return 404, matching the source Portal.
A lookup event invokes the static policy callback after filesystem work completes.
`StaticActionKind.List` lists the opened directory. `ServePath` performs another
root-relative lookup of an owned path; this supports explicit index or SPA choices.
`Reject` selects an error status. The default missing-path root-listing action selects
`/`, not the request's missing path; the directory policy still applies, so Portal
sets both `MissingFilePolicy.RootListing` and `DirectoryPolicy.List`. Fallback loops stop at `fallbacks_max` (default
and hard maximum 4). Enumeration or rendering failures return a bounded error.

Gzip negotiation is enabled by default and can be disabled with `gzip: false`.
The parser accepts case-insensitive codings and integer qualities from 0 through
1000, including wildcard and identity exclusions. An explicit gzip quality overrides
the wildcard; duplicate coding entries use the lowest quality. Empty or absent
Accept-Encoding selects identity. Malformed lists disable gzip while retaining any
parsed identity exclusion; combined fields over 4096 bytes cannot select a truncated
value. A usable gzip coding must have positive quality at least the identity quality.
If identity is forbidden and no acceptable compressed representation is available,
the response is 406. Negotiated responses vary on Accept-Encoding, including
identity responses, conditional responses and range responses.

The worker opens the original and its `.gz` sibling with the same rooted rules.
Missing, unreadable, nonregular or stale siblings leave the original selected.
Gzip may be equally new or newer; an older sibling is accepted only when its age
is strictly less than the configured positive freshness tolerance. Thus 10 ms
matches the observed Portal threshold, while the default 0 accepts no older file.
Freshness arithmetic uses seconds/nanoseconds with overflow checks. The original
resource path supplies MIME; the selected opened file supplies Content-Length,
Last-Modified, default ETag and all range bytes. Gzip selections carry
`Content-Encoding: gzip`. Application validators see selected-representation
metadata and must not issue the same strong validator for distinct encoded bytes.

Limits are explicit: paths 4096 bytes; request targets/redirects 8192 bytes; at most
128 directory entries scanned; at most 32768 packed listing bytes; at most 32768
rendered bytes; and the existing stream chunk limits. `entries_max`,
`listing_bytes_max`, `output_bytes_max`, `fallbacks_max`, and `pending_bytes_max`
allow smaller caps. Count limits include skipped nonregular entries, bounding scan
work. Listing output is atomic on cap failure. Native cancellation keeps a directory
or file descriptor alive until its pending worker operation finishes.

Source behavior was verified in PromptNook's `backend/goose/http_posix.c`:
`pn_static_append_listing` (line 1507) and `pn_portal_static` (line 1647). Deliberate
corrections include honoring q=0, representation-specific validators, bounded sorted
listings, no symlink traversal, safe redirects, and HEAD body suppression. Portal's
root listing on missing files is preserved by explicit configuration. The socket
fixture exercises root, subdirectory, missing resource, method rejection and custom
index/SPA policy, alongside gzip freshness, validators and ranges.
