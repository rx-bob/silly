# JSON input and output

E4.S3 adds opt-in typed binding and direct bounded serialization. Import `silly`.
Raw handlers retain control of parsing, duplicate keys, null omission and diagnostics.

## Exact bytes and application parsers

`ctx.body()` returns collected request bytes unchanged; unavailable bodies reject with
400. `ctx.json_reader()` constructs the standard `json::Reader` over those exact bytes.
Neither helper checks media type or imposes typed binding policy. Applications may use
standard readers and their own source offsets, errors and duplicate handling.

`ctx.json_bytes(status, payload)` copies opaque application JSON and sets
`Content-Type: application/json`. It does not parse or rewrite bytes. The caller owns
JSON validity; response metadata and output limits still apply. The ordinary local-error
variant is `respond_json_bytes`. Successful response helpers return normally; guarded
helpers exit the endpoint only on failure.

## Views, bounds and ownership

`parse_json(input, scratch, limits)` returns a fixed-size `JsonDocument` with `value`,
`error` and `error_at`. It validates the complete JSON grammar, UTF-8, escapes and
surrogate pairs before changing scratch. It builds no document tree. `json_object` /
`next_json_member`, `json_array` / `next_json_element`, `json_member` and `json_string`
provide borrowed traversal. Use views from a successful parser, not manually forged views.

`JsonLimits` defaults to 65,536 body bytes, 65,536 decoded bytes, depth 64 and 1,024
collection entries. Depth cannot exceed 256. Collection entries count all object members
and array elements across the document. Decoded bytes include keys and borrowed strings;
existing scratch plus newly decoded escaped strings is also capped. Syntax errors leave
scratch unchanged. Syntactically valid numbers need not fit a machine scalar until binding.

Unescaped strings borrow the input. Escaped keys and values borrow caller-owned scratch,
which is populated before exposing views. Keep both owners alive and do not mutate/reset
them while views or bindings remain live. Option slices retained in a binding must also
remain alive. Compiler-negative fixtures enforce input and scratch ownership.

## Typed binding

`bind_json<T>(document.value, options)` returns `JsonBinding<T>` with `value`, `source`,
`options`, `error` and `error_at`. Failed binding returns the default model, not a partial
successful value. `parse_json_body<T>(request, scratch, options)` also checks media type.
`require_json_binding<T>(ctx, scratch, options)` rejects failures through the endpoint;
`require_json<T>` returns only the model. Models must be fixed-size, including borrowed
slices and inline bounded collections; owned growable return models are rejected.

Supported scalars are bool, signed/unsigned 8/16/32/64-bit integers, finite f32/f64 and
byte-slice strings. Integer binding requires an integer token and checks range. Ordinary
nested structs bind recursively. Unknown fields and duplicates reject by default;
`JsonUnknown.Ignore` and `JsonDuplicate.First` / `Last` opt into alternatives. Keys are
compared after decoding, so `id` and `i\u0064` are duplicates. Ignored subtrees still
undergo syntax and limit validation; their object fields are not typed-bound.

`JsonAlias { field: "workspace_id", wire: "workspaceId" }` explicitly maps keys.
Aliases and field rules apply by field name throughout nested models. Invalid UTF-8,
duplicate mappings and mapped/unmapped key collisions reject as invalid options.
No implicit snake_case conversion occurs.

Every field is required by default, even with a Goose declaration default. Add
`JsonFieldRule { field, policy }` entries to `JsonBindOptions.fields` explicitly:

| Policy | Missing | Null | Present |
| --- | --- | --- | --- |
| Required | Error | Type error | Bind |
| Defaulted | Declared seed | Type error | Bind |
| Nullable | Error | Declared seed | Bind |
| Optional | Declared seed | Declared seed | Bind |

`json_field_presence(binding, field)` returns `JsonPresence.Missing`, `Null` or `Present`.
Retain the binding rather than only its model when this distinction matters.

`bind_json_with` accepts a static custom reader. Compose fields with `json_read_field`
and `json_read_field_with`; `json_read_array` fills an exact-size fixed array and
`json_read_list` fills an inline bounded list. See `tests/json_body_test.goose` for working
nested collection adapters and borrowed string collections. These explicit adapters avoid
ambiguous generic struct/array overloads in the current compiler.

Typed body helpers accept one `application/json` or `application/*+json` Content-Type,
optionally with a single UTF-8 charset parameter. Unsupported media rejects with 415;
body/scratch/collection limits use 413, invalid configuration uses 500, and other input
errors use 400. Raw helpers leave these policies to the application.

## Direct output

`JsonWriter { output, cap, options, .. }` appends to the supplied owner. `write_json`
handles supported scalar types, `JsonNull` and ordinary nested structs.
`write_json_array` handles collection slices; slice byte arrays explicitly for string
output, or use the named array writer for numeric byte arrays. Enum and optional-reference
output are unsupported compile-time errors. Invalid UTF-8 and nonfinite floats fail.

`write_json_object_with(writer, model, field_writer)` supplies custom static field
writers, including collection adapters. `tests/json_writer_test.goose` demonstrates a
nested PromptNook-shaped object with camelCase aliases and arrays of structs. No
whole-document intermediate string is created; numeric formatting uses small scalar
temporaries. Callbacks must use bounded writer operations and preserve JSON syntax.

`ctx.json(status, model, options)` handles ordinary models;
`ctx.json_with_fields(status, model, options, field_writer)` composes custom fields;
`ctx.json_with(status, values, options, silly::write_json_array)` supports root arrays.
Corresponding `respond_json*` helpers return local response errors.
`JsonWriteOptions` provides aliases, depth (default 64) and total collection cap (1,024).
Output is capped by the response limit. Writer errors are sticky; partial bytes may exist
in uncommitted output, and the endpoint error renderer replaces the failed response.

## Validation

View, grammar, binding, writer, response and raw-consumer fixtures pass in debug and
optimized builds on macOS. Ownership/unsupported-type fixtures fail compilation as
intended. Socket tests cover typed input, aliases, exact raw emission, repeated malformed
input, duplicate/unknown/type/media errors, output overflow and subsequent healthy requests.
