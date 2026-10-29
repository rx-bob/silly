// Bounded query metadata owns its list; byte views borrow request or caller scratch.
namespace silly;

import.url;

enum QueryError {
    None,
    InvalidEscape,
    PairLimit,
    DecodedLimit,
    InputLimit,
    InvalidOptions,
}
struct QueryOptions {
    separators: const u8[:] = "&",
    invalid_escape: InvalidEscape = InvalidEscape.Strict,
    input_bytes_max: i64 = 65536,
    pairs_max: i64 = 1024,
    decoded_bytes_max: i64 = 65536,
}
struct QueryPair {
    key: const u8[:] = "",
    value: const u8[:] = "",
    raw_key: const u8[:] = "",
    raw_value: const u8[:] = "",
    has_equals: bool = false,
}
struct QueryPairs {
    error: QueryError = QueryError.None,
    pairs_max: i64 = 1024,
    entries: QueryPair[>..] = [],
}
struct RawQueryIterator {
    input: const u8[:] = "",
    separators: const u8[:] = "&",
    cursor: i64 = 0,
    pending: bool = false,
    count: i64 = 0,
    pairs_max: i64 = 0,
    error: QueryError = QueryError.None,
}
struct RawQueryItem {
    present: bool = false,
    pair: QueryPair = QueryPair {
    },
    error: QueryError = QueryError.None,
}
enum KeyMatch {
    Exact,
    AsciiIgnoreCase,
}
struct QueryView {
    raw: const u8[:] = "",
    decoded: const u8[:] = "",
    options: QueryOptions = QueryOptions {
    },
    error: QueryError = QueryError.None,
    count: i64 = 0,
}
struct QueryIterator {
    raw: RawQueryIterator = RawQueryIterator {
    },
    decoded: const u8[:] = "",
    options: QueryOptions = QueryOptions {
    },
    decoded_cursor: i64 = 0,
}
const EMPTY_QUERY_PAIRS: QueryPair[0] = [];
struct QueryValues {
    entries: const QueryPair[:] = EMPTY_QUERY_PAIRS,
    from_view: bool = false,
    iterator: QueryIterator = QueryIterator {
    },
    name: const u8[:],
    cursor: i64 = 0,
}
struct QueryPresence {
    present: bool = false,
    error: QueryError = QueryError.None,
}
