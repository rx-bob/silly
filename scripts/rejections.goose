// Expected compiler failures are matched by diagnostic, never by exit status alone.
namespace silly_check;

struct Rejection {
    source: const u8[:],
    diagnostic: const u8[:]
}
const REJECTIONS: Rejection[27] = [
    Rejection {
        source: "tests/lifetimes/borrowed_queue_rejected.goose",
        diagnostic: "queue elements must be flat"
    },
    Rejection {
        source: "tests/lifetimes/endpoint_guard_rejected.goose",
        diagnostic: "return from silly::endpoint: no enclosing call of silly::endpoint on this compile-time call path"
    },
    Rejection {
        source: "tests/lifetimes/endpoint_reject_rejected.goose",
        diagnostic: "return from silly::endpoint: no enclosing call of silly::endpoint on this compile-time call path"
    },
    Rejection {
        source: "tests/lifetimes/header_index_reset_rejected.goose",
        diagnostic: "cannot clear index while values is still used"
    },
    Rejection {
        source: "tests/lifetimes/header_iterator_reset_rejected.goose",
        diagnostic: "cannot clear bytes while values is still used"
    },
    Rejection {
        source: "tests/lifetimes/header_value_reset_rejected.goose",
        diagnostic: "cannot clear bytes while value is still used"
    },
    Rejection {
        source: "tests/lifetimes/html_writer_escape_rejected.goose",
        diagnostic: "storing a reference rooted at scope, which does not outlive the destination: it is reached through a reference that may point into the caller's storage behind ctx"
    },
    Rejection {
        source: "tests/lifetimes/immutable_request_rejected.goose",
        diagnostic: "cannot assign through this path (const, or a read-only instantiation, §9.5)"
    },
    Rejection {
        source: "tests/lifetimes/json_binding_input_reset_rejected.goose",
        diagnostic: "cannot clear input while bound is still used"
    },
    Rejection {
        source: "tests/lifetimes/json_binding_scratch_reset_rejected.goose",
        diagnostic: "cannot clear scratch while bound is still used"
    },
    Rejection {
        source: "tests/lifetimes/json_owned_binding_rejected.goose",
        diagnostic: "resizable field value of struct JsonBinding must be the final field"
    },
    Rejection {
        source: "tests/lifetimes/json_writer_enum_rejected.goose",
        diagnostic: "fields requires a concrete struct or variant type, got Unsupported"
    },
    Rejection {
        source: "tests/lifetimes/json_writer_optional_rejected.goose",
        diagnostic: "no matching overload for call to json_default_field"
    },
    Rejection {
        source: "tests/lifetimes/local_escape_rejected.goose",
        diagnostic: "returning a reference rooted in bytes, which dies with this function"
    },
    Rejection {
        source: "tests/lifetimes/output_clear_rejected.goose",
        diagnostic: "cannot clear output while transport_view is still used: it may hold a reference or slice into it"
    },
    Rejection {
        source: "tests/lifetimes/producer_input_escape_rejected.goose",
        diagnostic: "storing a reference rooted at out, which does not outlive the destination"
    },
    Rejection {
        source: "tests/lifetimes/public_stream_resizable_rejected.goose",
        diagnostic: "default<T>() needs a fixed-size type, not public_stream_resizable_rejected::DynamicState"
    },
    Rejection {
        source: "tests/lifetimes/query_input_reset_rejected.goose",
        diagnostic: "cannot clear input while value is still used"
    },
    Rejection {
        source: "tests/lifetimes/query_scratch_reset_rejected.goose",
        diagnostic: "cannot clear scratch while value is still used"
    },
    Rejection {
        source: "tests/lifetimes/query_view_reset_rejected.goose",
        diagnostic: "cannot clear scratch while value is still used"
    },
    Rejection {
        source: "tests/lifetimes/request_clear_rejected.goose",
        diagnostic: "cannot clear bytes while request is still used"
    },
    Rejection {
        source: "tests/lifetimes/resizable_stream_rejected.goose",
        diagnostic: "default<T>() needs a fixed-size type, not resizable_stream_rejected::DynamicState"
    },
    Rejection {
        source: "tests/lifetimes/response_policy_clear_rejected.goose",
        diagnostic: "cannot clear router while plan is still used"
    },
    Rejection {
        source: "tests/lifetimes/route_capture_reset_rejected.goose",
        diagnostic: "cannot clear target while value is still used"
    },
    Rejection {
        source: "tests/lifetimes/route_plan_clear_rejected.goose",
        diagnostic: "cannot clear bytes while plan is still used"
    },
    Rejection {
        source: "tests/lifetimes/route_plan_mutation_rejected.goose",
        diagnostic: "cannot assign through this path (const, or a read-only instantiation, §9.5)"
    },
    Rejection {
        source: "tests/lifetimes/stream_state_escape_rejected.goose",
        diagnostic: "storing a reference rooted at state, which does not outlive the destination: it is reached through a reference that may point into the caller's storage behind ctx"
    },
];
