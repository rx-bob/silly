# Compiler lifetime and ownership contracts

Run all 28 fixtures independently: 27 negative contracts and one positive
`scoped_views.goose` contract. A failed import or syntax error is never evidence
of the intended rejection. The verification runner checks a specific diagnostic
fragment for each rejected fixture in debug and optimized builds.

| Fixture | Required diagnostic fragment (or successful result) |
| --- | --- |
| `borrowed_queue_rejected.goose` | `queue elements must be flat` |
| `endpoint_guard_rejected.goose` | `return from silly::endpoint: no enclosing call of silly::endpoint on this compile-time call path` |
| `endpoint_reject_rejected.goose` | `return from silly::endpoint: no enclosing call of silly::endpoint on this compile-time call path` |
| `header_index_reset_rejected.goose` | `cannot clear index while values is still used` |
| `header_iterator_reset_rejected.goose` | `cannot clear bytes while values is still used` |
| `header_value_reset_rejected.goose` | `cannot clear bytes while value is still used` |
| `html_writer_escape_rejected.goose` | `storing a reference rooted at scope, which does not outlive the destination` |
| `immutable_request_rejected.goose` | `cannot assign through this path` |
| `json_binding_input_reset_rejected.goose` | `cannot clear input while bound is still used` |
| `json_binding_scratch_reset_rejected.goose` | `cannot clear scratch while bound is still used` |
| `json_owned_binding_rejected.goose` | `resizable field value of struct JsonBinding must be the final field` |
| `json_writer_enum_rejected.goose` | `fields requires a concrete struct or variant type, got Unsupported` |
| `json_writer_optional_rejected.goose` | `no matching overload for call to json_default_field` |
| `local_escape_rejected.goose` | `returning a reference rooted in bytes, which dies with this function` |
| `output_clear_rejected.goose` | `cannot clear output while transport_view is still used` |
| `producer_input_escape_rejected.goose` | `which does not outlive the destination` |
| `public_stream_resizable_rejected.goose` | `default<T>() needs a fixed-size type` |
| `query_input_reset_rejected.goose` | `cannot clear input while value is still used` |
| `query_scratch_reset_rejected.goose` | `cannot clear scratch while value is still used` |
| `query_view_reset_rejected.goose` | `cannot clear scratch while value is still used` |
| `request_clear_rejected.goose` | `cannot clear bytes while request is still used` |
| `resizable_stream_rejected.goose` | `default<T>() needs a fixed-size type` |
| `response_policy_clear_rejected.goose` | `cannot clear router while plan is still used` |
| `route_capture_reset_rejected.goose` | `cannot clear target while value is still used` |
| `route_plan_clear_rejected.goose` | `cannot clear bytes while plan is still used` |
| `route_plan_mutation_rejected.goose` | `cannot assign through this path` |
| `scoped_views.goose` | Success without copy-on-return warnings. |
| `stream_state_escape_rejected.goose` | `storing a reference rooted at state, which does not outlive the destination` |

From the repository root, individual checks use:

```text
goose check tests/lifetimes/scoped_views.goose --offline -O0 --debug
goose check tests/lifetimes/scoped_views.goose --offline -O2
goose check tests/lifetimes/request_clear_rejected.goose --offline -O0 --debug
goose check tests/lifetimes/request_clear_rejected.goose --offline -O2
```

The last two commands must fail with the table's lifetime diagnostic. The
positive fixture must succeed in both modes. See `scripts/check.goose` for the
full deterministic compiler and functional suite.

The compiler tracks last use, so reset after a view's final use may be accepted
inside the same lexical block. Rejected fixtures deliberately use their views
after reset. Grow-only append preserves existing bytes, while clearing or
shrinking their owner requires ending all dependent borrows first.

The endpoint cases prove that terminal helpers require an enclosing endpoint on
every static call path. Stream cases reject borrowed producer input, escaping
handler-local state, and resizable state even when sinks are explicitly initialized.
The JSON-owned-binding fixture rejects a dynamic field before the binding result's
error field; this is a layout restriction, not a JSON parse diagnostic.

`tests/api_contract_test.goose` separately proves static callback shapes using
clearly labelled proof-local adapters. Functional route, stream, continuation,
queue and lifecycle tests prove runtime commitment, once-only cleanup, generation
routing and cancellation; compiler rejection alone does not establish those
protocol properties.
