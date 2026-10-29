# Buffered response helpers

E5.S1 implements the response forms in `reference/responses.goose`. Import `silly` and
call them inside a checked endpoint. Successful helpers prepare a response and return
normally; they do not imply transport delivery. Failures stop the endpoint through the
existing guard boundary. Every helper rejects a second response, including an attempt
after a response was already prepared. Failed partial output remains uncommitted and the
configured error renderer handles it using fresh storage.

| Helper | Output |
| --- | --- |
| `ctx.text(status, payload)` | Exact bytes; `text/plain; charset=utf-8` |
| `ctx.html(status) { out => ... }` | Direct bounded HTML; `text/html; charset=utf-8` |
| `ctx.json_bytes(status, payload)` | Existing opaque JSON contract; `application/json`, caller owns validity |
| `ctx.empty(status)` | Empty body, no Content-Type |
| `ctx.bytes(status, payload, options)` | Exact arbitrary bytes, including NUL; metadata optional |
| `ctx.redirect(status, location)` | Empty body and Location; no Content-Type |
| `ctx.attachment(status, payload, metadata)` | Copied bytes with validated attachment disposition |

The local-error alternatives `respond_text`, `respond_empty`, `respond_bytes`,
`respond_redirect`, `respond_attachment` and `respond_json_bytes` return `ResponseError`
without exiting the endpoint. They are usable outside a guarded callback. The guarded
HTML callback has no pretend local-error equivalent: writer operations themselves may
exit the endpoint. Existing response wire rules still govern HEAD, 204, 205 and 304.

## HTML contexts and ownership

`EndpointWriter` is passed to the static HTML callback immediately. It borrows response
storage and a callback-local scope token. The compiler rejects retaining it in longer-lived
application state. Implementation uses the `HtmlWriter<Response>` alias to defer guard
specialization until an endpoint call; application code can name `EndpointWriter`.

Use `silly::append(out, trusted_markup)` for literal markup. The trust decision is explicit;
no escaping or UTF-8 normalization occurs. Use the namespaced call because built-in
`.append` syntax shadows custom writer methods in the current compiler.

`html_text(out, value)` escapes `&`, `<` and `>` for ordinary HTML data/RCDATA text.
`html_attribute(out, value)` additionally escapes both quotes and TAB/LF/CR as character
references. Write the surrounding single or double quotes yourself. These operations do
not secure script, CSS, event-handler, URL, comment, attribute-name or unquoted-attribute
contexts. URL authorization and URI encoding remain application responsibilities.

Escaped text must be valid UTF-8. NUL, DEL and other C0 controls except TAB/LF/CR reject
with `ResponseError.Application`; `html_valid_text` exposes the same validation for input
handling before application state changes. Both escaping functions append spans/entities
directly to response-owned output, without a whole-document temporary. Output caps include
expanded entities. All writer operations enforce the response preparation phase and cap;
on overflow, execution stops before subsequent callback/handler statements.

## Metadata rules

`BodyOptions { content_type: "", charset: "", content_disposition: "" }` omits all optional
metadata. A content type must be a bare token/token MIME type. Charset is a separate token
and requires a content type. Content-Disposition is application-provided printable ASCII.
All supplied metadata rejects control bytes, including TAB and DEL, and is copied into
bounded response owners. Nothing infers JSON media type for binary or empty responses.

`Attachment { filename, content_type: "application/octet-stream", charset: "" }` constructs
`attachment; filename="..."`. Names must be nonempty ASCII basenames, excluding `.` / `..`,
path separators and controls. Double quotes are escaped inside the quoted value. Unicode
filenames and `filename*` encoding are not supported by this helper. Passing an empty
content type deliberately omits it. Metadata lengths are checked before allocating composed
charset/disposition strings, then common header count/byte limits are enforced.

Redirect accepts 301, 302, 303, 307 or 308. Location must be nonempty visible ASCII without
spaces or controls; callers encode URI characters as needed. This prevents header injection
but does not choose trusted redirect destinations. Response status, output cap and common
metadata checks apply consistently to every helper.

## Runnable form and checks

Build `examples/web.goose` and open `http://127.0.0.1:8083/`. GET displays a form whose
prefilled value uses quoted-attribute escaping. POST decodes bounded URL-encoded input,
validates a nonempty UTF-8 name, copies it into demo-owned state and redirects with 303.
The result page escapes the name as HTML text. Invalid names leave previous demo state
unchanged. This is an in-memory, single-owner demonstration, not durable user storage.

`tests/support/web_server_test.goose` runs the real example handlers through GET, POST, redirect,
escaped result and form prefill on one persistent socket with short writes. It includes
quotes, script-shaped input, ampersands, NUL and invalid UTF-8. `tests/response/html_test.goose`
covers contexts, limits and guard exits; its lifetime negative rejects escaped writers.
`tests/response/responses_test.goose` covers binary bytes, optional metadata, injection, exact
capacity boundaries and duplicate-response rejection through helpers.
