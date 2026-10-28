# E1.S3 nonblocking server

The package now serves real bounded GET requests over numeric IPv4/IPv6 listeners on
macOS and Linux. `examples/hello.goose` is an external package consumer. It sends a
buffered response through the actual parser, response builder, HTTP head writer and
vectored native transport. The reference applications remain the E3+ API targets.

```text
goose build examples/hello.goose --offline -O2 -o /tmp/silly-hello
/tmp/silly-hello
```

The example listens on `127.0.0.1:8081`. A GET with a Host header returns
`hello from silly\n`, an explicit Content-Type, Content-Length, and Connection: close.
Build with `-O0 --debug` for runtime checks. Core requires a POSIX C compiler and the
Goose runtime, not libcurl, databases, zlib or application native adapters.

## Delivered entry points and scope

`serve_buffered(options: ServerOptions, handler) -> ServerResult` accepts one static
`handler(Context<NoState, NoStream>&)` callback for every admitted GET. Handler prepares
a response with E1.S2's checked operations. There are no stored closures, routing mocks
or hidden suspended handler frames. E3 adds startup `Router<R>` and the target `serve<R>`
adapters on this server path. This staged low-level entry point does not replace that
target contract.

`run_server(options, listener, wake_reader, handler)` is the embeddable single-owner
entry point. It consumes listener and wake reader on **every** return path. Callers must
relinquish their descriptor copies, including copies passed to an owning Goose thread.
A wake byte or a closed wake writer stops admission and cancels pending connections,
then closes the listener and reader. This is explicit immediate cancellation, not E6's
graceful drain. `serve_buffered` creates its own listener/wake pair; normal application
signal orchestration belongs to E6. The hello process uses default OS signal handling.

`ServerResult` carries `ok`, typed `ServerError`, process-lived diagnostic text, and
native error number. Invalid options, listener/accept, wake setup, poll and clock errors
are explicit. Each connection independently closes on EOF, disconnect, deadline or
failed transport; one failed client does not terminate the listener. EINTR and
would-block return control to the scheduler without changing pending offsets.

E2.S1 now validates incremental HTTP/1.0 and HTTP/1.1 heads, including all four
request-target forms, strict Host/singleton fields and unambiguous body framing.
E2.S2 now collects fixed-length and chunked bodies into separate bounded request storage,
including Expect handling and pre-body route caps. The direct callback API remains GET-only;
prepared routing admits registered methods, including empty POST. Connections still close
after one response. See [request bodies](request_bodies.md) for limits, early rejection,
streaming primitives and inactivity policy, and [request heads](http_heads.md) for syntax.

`http_parser.goose` provides incremental `scan_head` and validated `parse_head`;
`parse_get_head` remains an exact-head compatibility adapter. Scanning examines only
newly appended bytes and retains offsets, not views. Parsed fields borrow the retained
input slab only until the handler returns. `http_writer.goose` serializes a separate
bounded HTTP head and generates framing, rejecting application framing overrides.
204/304 suppress Content-Length and reject nonempty bodies; 205 requires an empty body.
A failed/missing handler response or unserializable head becomes a bounded empty 500
before commitment. E2.S3 now supplies [response semantics and custom precommit rendering](response_wire.md).

## Ownership and bounded scheduling

Connection descriptors are fixed-size `Connection` values: descriptor, generation,
phase, input/transfer lengths and offsets, scan state and last-progress timestamp.
No handler-local reference is retained in them. Startup allocates separate bounded
input-head, HTTP-response-head, request-body, response-body and staging slabs; slot indices determine each slab range. Slots are
reconstructed on admission, increment generation and reset all counters. Generations
never wrap; an exhausted slot stays unavailable. E1.S4 adds queued completion identity
proofs before asynchronous work is introduced.

Each poll turn accepts at most `accepts_per_turn`, visits at most `connections_max`
slots, and performs one bounded read or vectored write per ready slot. Read/write sizes
are capped by `work_bytes_per_turn`. The write path advances header and body offsets
from the exact count returned by sendmsg, including a partial write crossing the vector
boundary. A non-reading socket remains pending while other ready sockets run. Deadline
checks use a monotonic clock and only actual I/O progress refreshes the idle timestamp.
Pure synchronous application callback work is bounded by its own algorithm; the server
cannot preempt a handler that does not return.

`ServerOptions` defaults: 16 connections, 64 KiB response heads, 512 MiB slab budget,
64 KiB I/O per slot/turn, 16 accepts/turn, 30-second idle timeout and 100-ms poll timeout.
E1.S2 Limits default to 32 KiB request heads and 8 MiB output. All five slab products
are checked by division/subtraction before allocation. Poll slots are capped at 1024,
including listener/wake; accepted connection slots are therefore at most 1022. All
resize growth supplies explicit fill values. Invalid options fail before admission.

The budget covers retained byte slabs, not the entire process. Slabs are eagerly
initialized; default body storage alone is 128 MiB. Descriptor/poll arrays and one
handler's temporary header/output builders are additional bounded storage. Buffered
payloads copy from application input into the response builder and then into the
connection-owned body slab. HTTP headers are separate and never concatenated with the
body. This slice makes no zero-copy or measured throughput claim. Future allocation
changes must preserve these ownership, generation and capacity contracts.

## Native boundary

`src/transport.goose` is the sole production FFI declaration module;
`native/transport.c` handles OS operations only. `silly_transport` exposes Descriptor,
IoResult/OpenResult/PairResult, listen/accept/read/write_parts/poll/close, monotonic time,
local port, wake sockets, and nonblocking connect helpers used by integration fixtures.
Results distinguish Ready, WouldBlock, Interrupted, Closed, Invalid and SystemError,
preserving errno. No native operation retains a Goose address after returning.

Sockets are nonblocking and close-on-exec. Linux writes use MSG_NOSIGNAL; macOS sockets
use SO_NOSIGPIPE. Descriptors invalidate before close; close is never retried on EINTR
because retry could hit a reused number. Repeated close is a no-op on the invalid owner.
Poll translates readiness/error/hangup into portable bits, using a bounded native stack
array. Native HTTP parsing, routing and response policy are deliberately absent.

Unexpected Goose aborts and externally copied raw descriptor values remain explicit
limits: C-owned resources do not automatically unwind, and ownership is a caller
discipline. The same limitation existed in the plan; E6 adds contained worker/shutdown
coordination. Normal return/error/cancellation paths close every owned descriptor.

## Verification

- `tests/transport_test.goose`: byte-exact two-vector transfer under a forced 4 KiB
  send buffer; partial progress in either vector; actual would-block, EOF, EPIPE and
  TCP reset; SIGPIPE safety; actual SIGALRM-interrupted poll; wakeups; descriptor reuse
  and close-once. Test-only timer/reset helpers live in its separate C sidecar.
- `tests/http_core_test.goose`: bytewise head fragmentation, exact caps, malformed
  request/header input, Host/framing/method/version policy, exact separate response head,
  conflicting application framing and atomic serializer failure.
- `tests/server_test.goose`: real loopback fast-client completion while an unread 4 MiB
  transfer remains pending, exact hello body/framing, wake cancellation and thread exit.
- `tests/server_state_test.goose`: option arithmetic, generations/reuse and retained
  transfer offsets through bounded writes (see test source for final assertions).

Build and run functional fixtures separately in `-O2` and `-O0 --debug` modes. E1.S2
positive and expected-rejection lifetime fixtures remain regression gates. No benchmark
or telemetry system was added. Socket tests need permission to bind local sockets.

Verified on 2026-10-26 with matching Goose runtime `4d3da949e563`:

| Platform | Compiler | Results |
| --- | --- | --- |
| macOS arm64 | Apple clang 17.0.0 | All nine functional/positive fixtures pass release/debug; four expected lifetime rejections match in both modes; actual hello loopback matches framing/body |
| Ubuntu 24.04 x64, Docker Desktop emulation | GCC 13.3 | Same nine fixtures pass release/debug; four expected rejections match in both modes; hello builds in both modes and release serves exact expected loopback bytes |

The nine fixtures are transport, HTTP core, server integration, server state, context,
headers, request, package consumer and positive scoped lifetime views. Strict native
C11 builds pass `-Wall -Wextra -Werror`. Final integration uses a 64 KiB slow-client
receive buffer: still backpressured by the 4 MiB response, without pathological tiny
TCP-window drain delays. Fast completion precedes wake; post-shutdown drain proves the
slow body remained incomplete. Linux artifacts are under `/tmp/silly-linux-results`
in this workspace; no consumer source or host compiler installation was changed.

`goose check examples/hello.goose -O2 --stacks --bce-lines` proves the direct copy kernel
`checkfree` (eight index accesses eliminated across its specializations). Other parser
and scheduler checks remain. Hello uses 14 data-stack regions at the compiler's default
2 GiB virtual reservation each; this is virtual address space, not resident memory.

The Pretty Goose formatter currently reports G015 on every non-const extern slice,
including writable destinations. The three destinations in `transport.goose` genuinely
receive bytes/events/descriptors and cannot be const. Check only that file with
`.goosefmt.ffi.toml`, which disables this one false-positive rule; use `.goosefmt.toml`
for every other file. All read-only native inputs retain const. No global suppression
or incorrect FFI annotation was introduced.

E3.S1 adds `serve<R>` with prepared routing; see [routing contracts](routing.md).
The routed path admits supported bodyless methods and suppresses HEAD payloads while
preserving representation Content-Length. `serve_buffered` remains GET-only.

Next in the plan: E3.S2, exact matching, captures, mounts and method policy.
