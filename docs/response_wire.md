# E2.S3 response framing and transfer

`prepare_response_head(out, response, ResponseWireOptions, cap)` returns a
`ResponseWirePlan` and writes only a complete, bounded HTTP head. The response must be
Prepared and the destination empty. All validation and size checks precede output
mutation; errors leave the destination unchanged and do not commit the response.
Header and payload owners remain separate. The compatibility `write_response_head`
entry point retains its buffered-GET contract and returns the planner's error.

Options carry HTTP minor version, request method, close policy (default true), and an
optional representation_length (default -1, unknown). The plan carries error, framing,
content_length, body_bytes and close policy. A negative body_bytes denotes an unknown
stream length; zero means no body may be transferred. Do not infer body emission from
the response's stored payload length after HEAD/status suppression.

| Response | Generated framing and payload behavior |
| --- | --- |
| Ordinary buffered final response | Content-Length equals buffered bytes; payload remains separate |
| HTTP/1.1 stream | Transfer-Encoding: chunked; caller frames each stable payload chunk |
| HTTP/1.0 stream | Connection: close, no Transfer-Encoding or Content-Length |
| HEAD | No payload; buffered length or explicit truthful representation length may appear |
| HEAD stream with unknown length | No Content-Length, Transfer-Encoding or payload |
| 204 | No Content-Length, Transfer-Encoding or payload |
| 304 | No payload; optional explicit truthful representation length, otherwise no Content-Length |
| 205 | Content-Length: 0 and no payload |

204/205/304 reject nonempty output. Stream mode likewise rejects queued output in the
response builder: its producer supplies separate payload chunks. Explicit representation
length is valid only for HEAD/304; a nonempty buffered HEAD must agree with it. Supplying
that metadata is the caller's assertion about the corresponding representation.
Successful CONNECT and 101 upgrades are rejected until a tunnel/upgrade driver exists.

`write_informational_head(out, status, fields, http_minor, cap)` atomically writes an
interim head with no content framing. It supports HTTP/1.1 statuses 100–199 except 101,
including repeated Link fields for 103. HTTP/1.0 informational output is rejected.
`begin_response` still accepts final statuses 200–599 only; interim output is a separate
operation, never a replacement for the final response. The server's real 100 Continue
path now uses this serializer and handles its failure before emitting bytes.

Application Content-Length, Transfer-Encoding, Connection, Trailer and Upgrade fields
are reserved and rejected, even when an asserted length would happen to match. Invalid
names/values and out-of-range owned field offsets fail validation. Count, owned metadata
bytes and complete serialized head bytes are bounded separately. Content-Type is never
invented; applications may omit it. Other fields preserve spelling, values and insertion
order, including duplicates. Redirect Location and custom final statuses survive; unknown
status reason text is the valid generic phrase Response.

`close=false` supports framing decisions for a persistence-capable caller. HTTP/1.0
unknown streams still force close; HTTP/1.0 known framing emits Connection: keep-alive.
The current server always requests close. Connection reuse remains E2.S4.

## Separate wire segments

`WireParts` borrows prefix, payload and suffix byte owners. `WireCursor` retains only
sent offsets, status and native error code. `write_wire(socket, cursor, parts, budget)`
offers at most two native vectors per call and reports actual transferred bytes. Keep
the same bytes/lengths alive until Complete or failure. Never clear or replace a payload
while its cursor still needs it; the API stores no pointer beyond the synchronous call.

Progress, Blocked and Interrupted preserve offsets for resumption. Complete, InvalidState
and Failed are terminal and repeat without another write. Negative budgets/invalid offset
order fail; zero budget blocks a nonempty transfer. OS errors propagate with their native
code. The server uses this same primitive, retains slab bytes until acknowledged, and
closes on transfer failure without attempting a second response after commitment.

`write_chunk_prefix(out, positive_length, cap)` creates bounded hexadecimal size/CRLF
bytes in a separate owner. Pass them as prefix, the stable chunk as payload, and CRLF as
suffix. Empty data does not terminate a stream: `write_chunk_end(out, cap)` explicitly
creates the final `0\r\n\r\n` segment. Response trailers are not supported yet; the
reserved Trailer header cannot promise them. HTTP/1.0 streaming sends payload segments
without chunk markers and ends by closing. `http_wire_test.goose` exercises both paths
through actual socket pairs, including binary zeros and forced backpressure.

These are wire primitives for E7's eventual application stream scheduler. The collected
handler server still rejects Stream mode before commitment; it cannot silently send a
chunked header and omit the terminal chunk.

## Precommit error rendering

`serve_with_errors<R>(options, define, handle, render)` accepts a named static
`render(Response&, ResponseFailure)` callback. Prepared-server and buffered-server
variants also exist; existing entry points use default_response_error. No callback
pointer or closure is stored in runtime connection state.

ResponseFailure distinguishes MissingResponse, HandlerFailure and Serialization, carries
its ResponseError, and defaults status to 500. The renderer receives fresh, empty bounded
owners after the failed handler frame has ended. It chooses status, body and end-to-end
headers with ordinary response operations, then prepares the response. Transport framing
and HEAD suppression still belong to the writer. A renderer that fails, omits preparation,
or exceeds metadata/body caps gets one bounded empty 500 fallback; it is never called
recursively. The fallback uses the validated request version and leaks no discarded
handler/renderer bytes.

This hook handles response-production failures before wire commitment. Classified
parser/admission/body/transport-error rendering is E2.S4 work. Transport failure after
commitment closes the connection; it cannot be converted into a new HTTP envelope.

Protocol basis: [RFC 9112 framing](https://www.rfc-editor.org/rfc/rfc9112.html#section-6.3),
[RFC 9110 Content-Length](https://www.rfc-editor.org/rfc/rfc9110.html#section-8.6), and
[informational responses](https://www.rfc-editor.org/rfc/rfc9110.html#section-15.2).

## Verification

All five new response/wire/socket fixtures pass on macOS in release and debug.
The Linux x86_64 regression passes 38 positive executables and 12 expected compiler
rejections per mode, plus the routed example build. Socket coverage includes real
backpressure, binary segments, short writes, HEAD, custom error envelopes, and
HTTP/1.0 admission errors. The final version-retention adjustment was retested with
the response socket fixture in both modes on both platforms.

The optimized response fixture reports six data-stack regions; bounds-check diagnostics
eliminate 15/16 index checks and 4/11 slice checks. No new unchecked annotations or
native dependencies were introduced. Formatting and whitespace checks pass.

Next in the plan: **E3.S2 — Implement exact matching, captures, mounts, and method policy**.
