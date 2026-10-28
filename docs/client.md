# Optional HTTP/HTTPS client transport

E9.S1 adds an explicitly imported package:

```goose
import silly_client from "../client";
```

`client/client.build` compiles the single native adapter translation unit and links
`libcurl` and zlib. The core `silly` package does neither. The core consumer executable was
built and run on macOS arm64; `otool -L` showed only `libSystem.B.dylib`.

The transport supports arbitrary token methods, buffered and streamed binary uploads,
structured final headers, explicit content decoding and streaming proxy composition. Redirects are never followed automatically, environment proxy settings are ignored,
and only HTTP/HTTPS URLs are admitted. There is no curl subprocess in request handling.

## Ownership and API

`start_client(ClientOptions)` returns `ClientStartResult`. One process-wide pool may
be active; a second start returns `ClientError.Busy`. Every request is identified by
an epoch/token `ClientRequest`; no callback retains a Goose pointer. `submit(client,
url)` synchronously copies the bounded URL, then returns immediately after admission.
The CA filename is copied when the client starts. URL and CA strings are limited to
4096 bytes and reject embedded control bytes.

The native worker alone configures easy handles, advances the multi handle and runs
foreign callbacks. The multi handle retains eligible upstream connections across
requests. Total, per-host and cached connection counts are limited by
`concurrency_max`; a completed request does not force its connection closed. DNS and
TLS-session caches are disabled to avoid additional cross-request cache growth; an
already-open eligible HTTP connection can still be reused.

Use `snapshot(request)` to inspect `Queued`, `Active`, `Complete` or `Failed`, typed
error and phase, final HTTP status, pending/received byte counts, connection creation
and pause counts. HTTP status is available after completion. `read(request, output)`
copies up to the available body bytes; a successful zero count means no data is
currently buffered, so inspect the snapshot to distinguish pending from completion.
A completed request can still have unread bytes. Transport failure discards buffered
bytes and subsequent reads return the typed error.

`headers(request, output)` atomically copies the retained raw final response header
block. Interim blocks and trailers are excluded; the cumulative byte budget still
counts every received block and trailer. A short destination returns `Limit` without
a partial copy. `response(request)` provides the normalized structured view described
below.

`cancel(request)` requests worker-owned cancellation. Keep the request handle until
its snapshot becomes terminal, then call `release(request)`. Release rejects live
requests with `Busy`, invalidates the caller's handle on success, and explicitly
discards unread bytes. Copied stale handles cannot name a later reused slot.

## Resource and scheduling bounds

Default `ClientOptions` values are:

| Option | Default | Bounds/meaning |
| --- | --- | --- |
| `concurrency_max` | 4 | 1–64 active requests/connections |
| `queue_max` | 16 | 0–(64 minus concurrency); additional retained slots |
| `response_header_bytes_max` | 16384 | 1–16384 cumulative raw header bytes |
| `response_body_bytes_max` | 67108864 | Positive total delivered body byte cap; decoded bytes in automatic mode |
| `request_header_bytes_max` | 16384 | 1–16384 copied request header bytes |
| `request_body_bytes_max` | 67108864 | Positive total admitted upload byte cap |
| `queue_timeout_ms` | 30000 | Time from admission while queued |
| `connect_timeout_ms` | 10000 | DNS, connection and TLS setup budget |
| `first_byte_timeout_ms` | 30000 | Established connection to response bytes |
| `idle_timeout_ms` | 30000 | Response/consumer inactivity, including a stalled consumer |
| `total_timeout_ms` | 0 | Optional admission-to-completion deadline; zero disables it |
| `poll_timeout_ms` | 100 | 1–1000; worker poll ceiling |
| `ca_file` | empty | System trust by default; optional application-selected CA file |

Queue, connect, first-byte and idle deadlines are positive and at most `INT_MAX`
milliseconds. A nonzero total deadline has the same maximum. Worker polling clips
its wait to the nearest applicable deadline and libcurl's own timer.

Capacity is `concurrency_max + queue_max`, at most 64 slots. Queued, active and
unreleased terminal requests all occupy slots. Saturation returns `Capacity` without
an unbounded queue. Request methods are capped at 32 bytes and header count at 128. Buffered upload
admission copies at most 65536 bytes; streamed upload admission uses a 16384-byte
pending window within that fixed native upload storage.

Each slot has one native body staging buffer of `CURL_MAX_WRITE_SIZE` (16384 bytes in
the selected build), fixed URL storage, bounded request/response header storage and a fixed upload buffer. Consumers may read
one byte at a time. A second incoming callback pauses before consuming any bytes while
the prior stage remains unread; libcurl replays that callback after capacity returns.
Libcurl can retain the paused callback chunk in addition to the native stage. No
whole response is accumulated by the adapter, and the configured total body limit
still applies across every resumed callback. HTTP/1.1 is forced to avoid multiplexed
stream buffering behind a paused consumer. See libcurl's
[pause contract](https://curl.se/libcurl/c/curl_easy_pause.html).

## Runtime integration and shutdown

`wake_descriptor(client)` returns a borrowed, nonblocking descriptor suitable for the
existing `silly_transport::poll` set. Never close that descriptor yourself. On wake,
call `drain_wake(client)` **before** inspecting all tracked request snapshots and
consuming available data. Notifications are coalescible hints, not one event per
request; inspect all tracked requests after every wake. This order prevents clearing
a notification after inspecting the state it was meant to announce. Consume pending
data or retain application interest until it has been drained; a partial read need
not generate another notification.

Native submission, consumption and cancellation wake the multi poll without running
foreign callbacks on the application thread. Snapshots and bounded copies use a short
native mutex; network progress and resolver/TLS cleanup run outside it on the worker.

`stop_client(client)` closes admission and requests cancellation of queued/active
requests. `finish_client(client)` returns `complete:false` until the native owner has
finished cleanup. Preserve the client handle and all shutdown ownership while it is
incomplete. A successful finish closes the notification descriptors, invalidates the
client handle and all remaining request handles, and permits a new pool epoch. Do not
poll a borrowed wake descriptor concurrently with its owner's successful finish.

## TLS, DNS and errors

HTTPS always enables certificate-chain verification and hostname verification.
There is no insecure option. A configured `ca_file` changes the trust input while
keeping both verification checks enabled. Startup requires libcurl 7.85.0 or newer
with SSL and asynchronous DNS support. The inspected macOS build is libcurl 8.7.1,
SecureTransport/LibreSSL, with asynchronous threaded DNS and thread-safe global
initialization. Unsupported builds fail explicitly instead of silently blocking the
application owner on synchronous resolution.

`ClientError` distinguishes `Dns`, `Connect`, `Tls`, `Timeout`, `Cancelled`, `Reset`,
`Limit`, `Protocol`, and resource/lifecycle errors. `ClientPhase` identifies queue,
connection, upload, response wait or body activity when a failure occurs. `native_code`
retains the underlying curl result where one exists. Application deadline or explicit
cancellation failures need not have a native curl error code.

Connection timeout covers DNS and protocol handshakes, as specified by
[libcurl](https://curl.se/libcurl/c/CURLOPT_CONNECTTIMEOUT_MS.html). Total timeout may
be disabled for a long-lived stream; finite phase/idle deadlines and all storage,
queue and connection caps remain in force.

## Methods and request bodies

`submit(client, url)` remains the raw GET shorthand. Use
`submit_request(client, url, RequestOptions)` for the extended surface:

```goose
const fields = [silly_client::RequestHeader {name: "Content-Type", value: "application/octet-stream"}];
let result = silly_client::submit_request(client, url, silly_client::RequestOptions {
    method: "PATCH",
    headers: fields,
    body_mode: silly_client::ClientBodyMode.Buffered,
    body: binary_bytes,
    ..
});
```

Methods are validated HTTP tokens. Header order and duplicate fields are retained;
empty values are sent as empty fields. Names and values reject injection bytes.
The adapter owns `Content-Length`, `Transfer-Encoding`, `Trailer`, `Connection`,
`Expect` and `Upgrade`; applications cannot inject competing framing. `Host` and
`Authorization` remain explicit application choices. All supplied bytes are copied
before admission returns. HTTP error statuses remain successful transport results,
with their original status and binary body; no JSON or text envelope is introduced.

`ClientBodyMode.None` sends no body. `Buffered` copies the supplied bytes, uses their
exact binary length, and is capped at 65536 bytes plus the configured total upload
limit. `Stream` accepts no initial body; `body_length >= 0` declares an exact length,
while `-1` selects chunked HTTP/1.1 upload. HEAD rejects upload modes and uses curl's
bodyless request operation rather than merely changing the method string.

For streaming, call `write_upload(request, bytes)` and advance only by its returned
count. Partial acceptance is normal; zero means backpressure. Retry on wake or retained
capacity. `finish_upload(request)` marks EOF after all bytes have been admitted and
rejects a declared-length mismatch. Known-length uploads also complete their read side
once the declared bytes have been supplied. Attempts to exceed the declared or
configured total length fail explicitly. An early final response may end the request
before the application has produced all bytes; inspect the terminal snapshot and stop
feeding it.

Upload starvation pauses curl's send side, while a full response stage pauses only
its receive side. The worker preserves the other pause flag when resuming one side,
so streamed upload and download can make progress independently. Upload activity uses
the idle budget; after the final upload bytes have been handed to curl, the first-byte
response budget begins. The optional overall deadline still includes queued/upload time.

## Final response views and decoding

`response(request)` returns an owned `ClientResponse`. `ready:false` means no complete
final header block yet; a transport failure before that point returns its typed error.
Once ready, metadata remains inspectable even if a subsequent body transfer fails;
`snapshot` remains the authority for transfer completion/error.

The response owns up to 128 ordered field offsets and 16384 header bytes.
`response_header(response, index)` yields a borrowed name/value view for ordered
iteration, including duplicates. `get_header(response, name)` performs an ASCII
case-insensitive first-match lookup and returns `HeaderValue {present, value}`.
`content_type(response)` is the optional Content-Type lookup. These views borrow the
response owner; do not retain them beyond that owner's lifetime or mutation.

`status_code`, `interim_count`, `decoded`, `bodyless` and `kind` expose classification.
Interim 100/103 blocks never replace final response headers. HEAD, 204 and 304 produce
no body. Recognized redirect statuses are 301, 302, 303, 307 and 308. Raw final headers
remain available through `headers`; malformed structured fields or excessive field
counts fail the structured view instead of returning a partial parse.

`ContentDecoding.Raw` is the default. HTTP transfer framing is still decoded: chunk
markers are not application bytes. An explicit request `Accept-Encoding` is passed
through unchanged and compressed response bytes remain compressed.
`ContentDecoding.Automatic` asks for `gzip, deflate` and enables the adapter's incremental zlib decoder;
a simultaneous custom Accept-Encoding is rejected. Curl still removes transfer framing, but automatic content decompression is disabled
inside curl: the adapter validates gzip/deflate completion and integrity itself.
A fixed 16384-byte compressed stage feeds a separate 16384-byte decoded stage; each
must drain before more data is accepted. The response body cap applies to decoded
bytes. Unsupported, truncated or malformed compression is a typed `Decoding` error.

Normalized fields always omit `Transfer-Encoding` and `Trailer`, since callers see
neither chunk framing nor the trailer block. A non-bodyless transfer-coded response
also drops Content-Length. When content decoding changes the representation, its
Content-Encoding and compressed Content-Length are omitted. HEAD/304 representation
Content-Encoding and Content-Length are preserved because no body was transformed.
Other fields retain their order and values. Transfer and content decoding are separate
operations; curl's [transfer decoding option](https://curl.se/libcurl/c/CURLOPT_HTTP_TRANSFER_DECODING.html)
describes the framing step.

`collect(request, output, limit, work_bytes = 16384)` is an optional nonblocking
consumer. Each call copies at most `work_bytes` (1–16384) and returns Pending,
Complete or Failed. It never allocates past the caller's declared total limit.
Exceeding that limit requests cancellation and returns `Limit`; retain the request
until terminal and release it normally. Already copied bytes remain caller-owned.
Complete means all response bytes have been consumed, not merely that curl stopped.

## Explicit redirect policy

`redirect_url(request, output)` resolves the retained Location against the request URL
without starting another connection. It accepts only HTTP/HTTPS targets, rejects
ambiguous or over-limit Location values, and leaves authorization decisions to the
caller. A short output owner returns `Limit`.

After draining the redirect response, the application may validate or rewrite that
URL and call `follow_redirect(client, parent, approved_url, fresh_options, max_hops)`.
The parent must be a completed recognized redirect. The helper defaults to five hops
and accepts a finite maximum from 1 through 16. The returned request retains the hop
count; the original request remains separately owned and must still be released.

No method, header, authorization, custom Host or body is inherited from the parent.
Default fresh options therefore make a GET; preserving a 307/308 method/body requires
an explicit new request description. A streamed body is never implicitly rewound or
replayed. This deliberately avoids curl auto-follow behavior that can forward custom
headers or preserve custom methods unexpectedly. See curl's [redirect behavior](https://curl.se/libcurl/c/CURLOPT_FOLLOWLOCATION.html).

## Verification

`tests/client_transport_test.sh` creates temporary local CA/server certificates and
starts a local HTTP/HTTPS fixture, then builds/runs the transport suite in Debug and
O2. Each mode uses an isolated native build cache so libcurl adapter C code is
compiled with the selected optimization too. Test tooling may invoke OpenSSL/Python; client request handling never invokes a
subprocess. Fixtures exercise HTTP/TLS success, untrusted and mismatched certificates,
connection reuse, DNS/connect/reset failures, delayed responses, limits, tiny-buffer
pause/resume, cancellation and bounded pool saturation. `tests/client_http_test.sh`
adds method/header/binary upload coverage, simultaneous upload/download pauses,
interim and bodyless responses, compression and decoded limits, collection caps and
explicit redirect handling. `tests/client_response_test.goose` exercises structured
metadata normalization and limits without a network fixture. Platform claims apply only
to the environment actually exercised; Linux remains a supported implementation target.

## Proxy composition

Add `import proxy from "../client";` alongside the client and core imports to opt into
server composition. `proxy_response(ctx, ProxyOptions)` admits an upstream request and selects a deferred,
duplex server stream. The context's stream state is `ProxyTransfer`; its callback calls
`proxy_step(state, event, out)` or `proxy_step_with_policy(state, event, out, map_error,
inspect)`. Register upload routes with `RouteOptions {body: BodyMode.Streamed, ..}`.
Use `ProxyOptions.headers` for optional overrides (`headers: []` is explicit).
For local programs importing both core and its nested client directory, Goose resolves
one package root: the program needs a `.build` manifest listing the client native source
and `curl`/`z` libraries. [The reference manifest](../reference/files_and_portal.build)
shows this opt-in linkage; core-only consumers remain free of those dependencies.
Buffered routes retain their existing body limit; proxying does not silently collect
streamed uploads. See [the Portal listener](../reference/files_and_portal.goose) for
composition with static files, explicit client startup, and shutdown.

`ProxyOptions.client` and `target_url` are application choices. `proxy_target(out,
base, path, query)` joins an approved HTTP/HTTPS base and selected path without parsing
or reordering query bytes. Target selection, prefix rewriting, allowlists, credentials,
status policy and audit logging belong to the application. Redirects remain responses;
the proxy never follows them automatically. Incoming method and binary body bytes are
preserved. Ordered header overrides use `ProxyOptions.headers`.

Authorization defaults to removal (`ProxyAuthorization.None`); `Incoming` explicitly
forwards it, and `Override` uses `authorization_value`. Host defaults to the target URL
(`ProxyHost.Target`); `Incoming` and `Override` are explicit alternatives. Forwarding
removes standard hop-by-hop fields and every field nominated by Connection on either
side. The server regenerates response framing. Raw content decoding is the default;
`ContentDecoding.Automatic` changes representation bytes and removes stale encoding
and length metadata. Duplicate end-to-end headers, redirects and HTTP error response
bodies remain intact.

The default `inspection_bytes_max:0` streams responses with bounded staging and gives
the inspection callback metadata plus an empty body slice. A positive value explicitly
requests complete-body inspection, capped at 32768 bytes; overflow becomes a typed
upstream failure before publishing response metadata. The callback receives
`ProxyInspection`, a mutable owned `ClientResponse`, and borrowed body bytes. Returning
zero preserves the status; returning 200–599 replaces it. The callback runs once before
publication. `ProxyOptions.tag` carries an application correlation value to inspection
and failure hooks. Body views must not escape the callback.

The error hook receives `ProxyFailure {error, phase, tag}` and returns a bounded
`ProxyErrorResponse {status, body, content_type}`. Defaults are 504 for timeout and 502
for other upstream failures. The mapped failure remains available until the first wire write, including a failure
after metadata selection while the first output chunk is pending. After that commitment,
failure terminates the downstream stream; it cannot produce a second status or append
an error envelope. Incoming body framing failures and downstream transport
failures use the server's normal stream cancellation/error policy.

Backpressure is independent in both directions. One residual upload chunk (at most
4096 bytes) waits for the native upload window. One server output chunk (configured by
`pending_bytes_max`, 1–4096) waits for downstream acknowledgement. The optional
inspection buffer has a fixed 32768-byte storage ceiling. Timed wakeups continue while
a downstream chunk is pending, allowing uploads, EOF and upstream failures to progress.
`poll_interval_ms` is 1–1000, default 1; the proxy uses these server timer wakeups rather
than adding the client's descriptor to the listener poll set. Native network progress
still runs only on the client worker. An early response while the inbound body remains
unfinished explicitly closes the downstream connection after its response.

`abandon(request)` relinquishes a client handle immediately and requests cancellation
of live work. The native worker retains and cleans active curl/decoder ownership before
reclaiming the slot. Completed requests discard unread bytes immediately. It is suitable
for one-shot stream cancellation callbacks; unlike `cancel` followed by `release`, no
later callback is needed to finish request cleanup. Client shutdown ownership remains
with the application.

### Consumer-selected Accept suppression

`RequestOptions.suppress_default_accept` and `ProxyOptions.suppress_default_accept`
default to false. When true and no explicit Accept field remains, the client suppresses
libcurl's default `Accept: */*`. An explicit empty Accept still sends an empty field;
an explicit nonempty Accept is preserved. The internal suppression directive consumes
one header slot and counts against request header bytes. Portal uses this public option
for its source behavior. See [Portal/MCP examples](promptnook_outbound.md).
