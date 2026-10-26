# E1.S2 compiler lifetime fixtures

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
