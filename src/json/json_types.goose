// Fixed JSON views borrow original input and caller-owned decoded-string storage.
namespace silly;

enum JsonError {
    None,
    InvalidOptions,
    BodyLimit,
    ScratchLimit,
    DepthLimit,
    CollectionLimit,
    Syntax,
    InvalidString,
    InvalidNumber,
    Type,
    Required,
    Duplicate,
    Unknown,
    OutputLimit,
    UnsupportedMediaType,
    BodyUnavailable,
}
struct JsonAlias {
    field: const u8[:],
    wire: const u8[:],
}
const EMPTY_JSON_ALIASES: JsonAlias[0] = [];
// collection_max bounds total members/elements; decoded_bytes_max bounds all string bytes
// and the final caller scratch length. Depth counts containers and is hard capped at 256.
struct JsonLimits {
    body_bytes_max: i64 = 65536,
    decoded_bytes_max: i64 = 65536,
    depth_max: i64 = 64,
    collection_max: i64 = 1024,
}
enum JsonKind {
    Null,
    Bool,
    Number,
    String,
    Array,
    Object
}
enum JsonDuplicate {
    Reject,
    First,
    Last
}
// Construct through parse_json; raw/decoded must remain alive and unmodified while views exist.
struct JsonValue {
    offset: i64 = 0,
    raw: const u8[:] = "",
    decoded: const u8[:] = "",
    kind: JsonKind = JsonKind.Null,
    limits: JsonLimits = JsonLimits {
    },
}
struct JsonDocument {
    value: JsonValue = JsonValue {
    },
    error: JsonError = JsonError.None,
    error_at: i64 = 0,
}
struct JsonMember {
    present: bool = false,
    key: const u8[:] = "",
    value: JsonValue = JsonValue {
    },
    error: JsonError = JsonError.None,
}
struct JsonElement {
    present: bool = false,
    value: JsonValue = JsonValue {
    },
    error: JsonError = JsonError.None,
}
struct JsonObjectIterator {
    value: JsonValue,
    cursor: i64 = 1,
    decoded_cursor: i64 = 0,
    done: bool = false,
    error: JsonError = JsonError.None,
}
struct JsonArrayIterator {
    value: JsonValue,
    cursor: i64 = 1,
    decoded_cursor: i64 = 0,
    done: bool = false,
    error: JsonError = JsonError.None,
}
fn valid_json_limits(limits: JsonLimits) -> bool {
    return limits.body_bytes_max >= 0 && limits.decoded_bytes_max >= 0
        && limits.depth_max >= 0 && limits.depth_max <= 256 && limits.collection_max >= 0;
}
