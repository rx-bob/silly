// Decoded lookup is explicit about presence, repetition and raw-key compatibility.
namespace silly;

import.query_decode;
import.query_raw;
import.query_types;
import.query_view;
import.request;

fn get(pairs: const QueryPairs&, name: u8[:]) -> FieldValue {
    if pairs.error != QueryError.None {
        return FieldValue {
        };
    }
    for pair in pairs.entries {
        if pair.key == name {
            return FieldValue {
                present: true,
                value: pair.value
            };
        }
    }
    return FieldValue {
    };
}

fn query_values(pairs: const QueryPairs&, name: u8[:]) -> QueryValues {
    return QueryValues {
        entries: pairs.entries,
        name: name,
        ..
    };
}

fn next_query_value(values: QueryValues&) -> FieldValue {
    if values.from_view {
        return next_query_view_value(values);
    }
    while values.cursor < values.entries.len {
        let pair = values.entries[values.cursor];
        values.cursor += 1;
        if pair.key == values.name {
            return FieldValue {
                present: true,
                value: pair.value
            };
        }
    }
    return FieldValue {
    };
}

fn query_ascii_lower(byte: u8) -> u8 {
    return if byte >= 'A' && byte <= 'Z' {
        byte + 32
    } else {
        byte
    };
}

fn query_key_equal(left: u8[:], right: u8[:], match_key: KeyMatch) -> bool {
    if left.len != right.len {
        return false;
    }
    for index in left.len {
        if match_key == KeyMatch.Exact {
            if left[index] != right[index] {
                return false;
            }
        } else if query_ascii_lower(left[index]) != query_ascii_lower(right[index]) {
            return false;
        }
    }
    return true;
}

fn query_key_filtered(key: u8[:], keys: (const u8[:])[:], match_key: KeyMatch) -> bool {
    for candidate in keys {
        if query_key_equal(key, candidate, match_key) {
            return true;
        }
    }
    return false;
}

fn without_query_keys(pairs: const QueryPairs&, keys: (const u8[:])[:],
    match_key: KeyMatch = KeyMatch.Exact) -> QueryPairs {
    var result = QueryPairs {
        error: pairs.error,
        pairs_max: pairs.pairs_max,
        ..
    };
    if result.error != QueryError.None {
        return result;
    }
    if pairs.pairs_max < 0 || pairs.entries.len > pairs.pairs_max {
        result.error = QueryError.PairLimit;
        return result;
    }
    for pair in pairs.entries {
        if !query_key_filtered(pair.key, keys, match_key) {
            result.entries.push(pair);
        }
    }
    return result;
}

fn query_error_status(error: QueryError) -> i32 {
    return if error == QueryError.InputLimit {
        414
    } else if error == QueryError.InvalidOptions {
        500
    } else {
        400
    };
}

fn query_pairs<A, S>(ctx: Context<A, S> & , scratch: u8[>..]&,
    options: QueryOptions = QueryOptions {
    }) -> QueryView {
    let raw = raw_query(ctx.request.target);
    let result = parse_query_view(raw.value, scratch, options);
    if result.error != QueryError.None {
        reject_text(ctx, query_error_status(result.error), "Invalid query");
    }
    return result;
}

fn query<A, S>(ctx: Context<A, S> & , name: u8[:], scratch: u8[>..]&,
    options: QueryOptions = QueryOptions {
    }) -> FieldValue {
    let raw = raw_query(ctx.request.target);
    let start = scratch.len;
    let error = prepare_query_scratch(raw.value, scratch, options);
    if error != QueryError.None {
        reject_text(ctx, query_error_status(error), "Invalid query");
    }
    return query_first_view(raw.value, scratch[start..], name, options);
}

// Narrow compatibility entry point: malformed query escapes remain literal, never path policy.
fn query_literal_invalid_escape<A, S>(ctx: Context<A, S> & , name: u8[:], scratch: u8[>..]&,
    options: QueryOptions = QueryOptions {
    }) -> FieldValue {
    var compatible = options;
    compatible.invalid_escape = InvalidEscape.Literal;
    return query(ctx, name, scratch, compatible);
}

// Resolve directly from caller-owned bytes, without returning a view rooted in local metadata.
fn query_first_view(raw: u8[:], scratch: u8[:], name: u8[:], options: QueryOptions) -> FieldValue {
    var iterator = raw_query_pairs(raw, options);
    var cursor: i64 = 0;
    while iterator.pending {
        let item = next_raw_query(iterator);
        if !item.present {
            break;
        }
        let key = query_piece_view(item.pair.raw_key, scratch, cursor, options);
        let value = query_piece_view(item.pair.raw_value, scratch, cursor, options);
        if key == name {
            return FieldValue {
                present: true,
                value: value
            };
        }
    }
    return FieldValue {
    };
}
