# E1 compiler lifetime and ownership fixtures

These are compiler contract tests. Files ending in `_rejected.goose` must fail
`goose check`; a failed import or syntax error does not count as a passing test.
Run each fixture independently so one rejection cannot hide another.

| Fixture | Expected result / diagnostic fragment |
| --- | --- |
| `scoped_views.goose` | Success without copy-on-return warnings. Borrowed request metadata and handler context stay within driver-owned roots. Grow-only output append preserves existing views; reset follows the final use. |
| `request_clear_rejected.goose` | Failure containing `cannot clear bytes` and `request is still used`. |
| `output_clear_rejected.goose` | Failure containing `cannot clear output` and `transport_view is still used`. |
| `local_escape_rejected.goose` | Failure containing `returning a reference rooted in bytes, which dies with this function`. |
| `immutable_request_rejected.goose` | Failure containing `cannot assign through this path`. |
| `stream_state_escape_rejected.goose` | Failure containing `storing a reference rooted at state, which does not outlive the destination`. A fixed-size struct cannot smuggle handler-local views into a stream sink. |
| `resizable_stream_rejected.goose` | Failure containing `default<T>() needs a fixed-size type`. Explicitly initializing the sink's state cannot bypass the fixed-size check in `start_stream`. |
| `borrowed_queue_rejected.goose` | Failure containing `queue elements must be flat`. Cross-thread messages cannot retain borrowed slice addresses. |

Example, from the repository root:

```text
goose check tests/lifetimes/scoped_views.goose
goose check tests/lifetimes/request_clear_rejected.goose
```

The second command must exit nonzero with the indicated lifetime diagnostic.
Validate positive and negative fixtures at `-O2` and `-O0 --debug`.

The installed compiler tracks last use: reset after the final dependent use can
be accepted even inside the same lexical block. The rejected fixtures deliberately
use each view after the attempted reset. Grow-only `u8[>..]` append is legal while
an older view is live; its existing bytes remain valid. Clearing or shrinking
that owner while the view is still needed is rejected. Response commitment and
transport acknowledgement additionally require runtime lifecycle checks; compiler
lifetimes alone do not prove those protocol states.

E1.S4 extends these checks to stream handoff and cross-thread messages. The positive
`tests/api_contract_test.goose` proves real Context/StreamStart ownership with the exact
three target callback overload shapes through clearly labeled proof-local adapters.
Its handler clears its local inline state after handoff; producer steps later observe
the retained owned copy. Runtime continuation and queue tests separately prove terminal
cleanup, generation rejection and targeted delivery; the compile-negative tests are not
a substitute for those state-machine assertions.

E3.S1 adds `route_plan_clear_rejected.goose` (diagnostic `cannot clear bytes`) and
`route_plan_mutation_rejected.goose` (`cannot assign through this path`). These prove
retained inventory ownership and const prepared entry access in both compiler modes.

E4.S1 adds `header_value_reset_rejected.goose` and
`header_iterator_reset_rejected.goose` (diagnostic `cannot clear bytes`), plus
`header_index_reset_rejected.goose` (`cannot clear index`). Each uses the retained value
or cursor after the attempted reset. `indexed_header_test.goose` exercises legal reset
after final use and fresh parsing with the reused byte owner.

E7.S1 adds `producer_input_escape_rejected.goose` (diagnostic `which does not
outlive the destination`) and `public_stream_resizable_rejected.goose` (diagnostic
`default<T>() needs a fixed-size type`). These reject retaining step-local input in
producer state and bypassing fixed-state checks through an explicitly initialized sink.
