// Query decoding validates all capacities before allocating metadata or growing scratch.
namespace silly;

import.query_raw;
import.query_types;
import.url;

struct QueryMeasure {
    error: QueryError = QueryError.None,
    decoded: i64 = 0,
    scratch: i64 = 0,
    count: i64 = 0,
}

fn query_decode_policy(options: QueryOptions) -> UrlDecodePolicy {
    return UrlDecodePolicy {
        plus_as_space: true,
        invalid_escape: options.invalid_escape
    };
}

fn measure_query_piece(measured: QueryMeasure&, raw: u8[:], options: QueryOptions) {
    let part = measure_url(raw, query_decode_policy(options));
    if part.error != UrlDecodeError.None {
        measured.error = QueryError.InvalidEscape;
    } else if part.bytes > options.decoded_bytes_max - measured.decoded {
        measured.error = QueryError.DecodedLimit;
    } else {
        measured.decoded += part.bytes;
        if part.transformed {
            measured.scratch += part.bytes;
        }
    }
}

fn measure_query(raw: u8[:], options: QueryOptions) -> QueryMeasure {
    var iterator = raw_query_pairs(raw, options);
    var measured = QueryMeasure {
    };
    while iterator.pending || iterator.error != QueryError.None {
        let item = next_raw_query(iterator);
        if item.error != QueryError.None {
            measured.error = item.error;
            return measured;
        }
        if !item.present {
            return measured;
        }
        measured.count += 1;
        measure_query_piece(measured, item.pair.raw_key, options);
        if measured.error != QueryError.None {
            return measured;
        }
        measure_query_piece(measured, item.pair.raw_value, options);
        if measured.error != QueryError.None {
            return measured;
        }
    }
    return measured;
}

fn append_query_piece(scratch: u8[>..]&, raw: u8[:], options: QueryOptions) {
    let policy = query_decode_policy(options);
    if measure_url(raw, policy).transformed {
        // Complete preflight guarantees success; no borrowed scratch views exist yet.
        let error = decode_url(scratch, raw, options.decoded_bytes_max, policy);
        assert(error == UrlDecodeError.None);
    }
}

fn query_piece_view(raw: u8[:], scratch: u8[:], cursor: i64&, options: QueryOptions) -> const u8[:] {
    let measured = measure_url(raw, query_decode_policy(options));
    if !measured.transformed {
        return raw;
    }
    let start = cursor;
    cursor += measured.bytes;
    return scratch[start..cursor];
}

fn query_bind_pairs(raw: u8[:], scratch: u8[:], options: QueryOptions) -> QueryPairs {
    var result = QueryPairs {
        pairs_max: options.pairs_max,
        ..
    };
    var iterator = raw_query_pairs(raw, options);
    var cursor: i64 = 0;
    while iterator.pending {
        let item = next_raw_query(iterator);
        if !item.present {
            return result;
        }
        let pair = item.pair;
        let key = query_piece_view(pair.raw_key, scratch, cursor, options);
        let value = query_piece_view(pair.raw_value, scratch, cursor, options);
        result.entries.push(QueryPair {
                key: key,
                value: value,
                raw_key: pair.raw_key,
                raw_value: pair.raw_value,
                has_equals: pair.has_equals
            });
    }
    return result;
}

fn prepare_query_scratch(raw: u8[:], scratch: u8[>..]&, options: QueryOptions) -> QueryError {
    let measured = measure_query(raw, options);
    if measured.error != QueryError.None {
        return measured.error;
    }
    if scratch.len > options.decoded_bytes_max || measured.scratch > options.decoded_bytes_max - scratch.len {
        return QueryError.DecodedLimit;
    }
    var iterator = raw_query_pairs(raw, options);
    while iterator.pending {
        let item = next_raw_query(iterator);
        if !item.present {
            break;
        }
        append_query_piece(scratch, item.pair.raw_key, options);
        append_query_piece(scratch, item.pair.raw_value, options);
    }
    return QueryError.None;
}

fn parse_query(raw: u8[:], scratch: u8[>..]&, options: QueryOptions = QueryOptions {
    }) -> QueryPairs {
    let start = scratch.len;
    let error = prepare_query_scratch(raw, scratch, options);
    if error != QueryError.None {
        return QueryPairs {
            error: error,
            ..
        };
    }
    return query_bind_pairs(raw, scratch[start..], options);
}
