// Raw query iteration preserves ordered empty entries and never interprets percent escapes.
namespace silly;

import.query_types;
import.request;

fn valid_query_options(options: QueryOptions) -> bool {
    return options.input_bytes_max >= 0 && options.pairs_max >= 0 && options.decoded_bytes_max >= 0
        && (options.separators == "&" || options.separators == "&;");
}

// Input is an HTTP request target; strict target validation belongs to the HTTP parser.
fn raw_query(target: u8[:]) -> FieldValue {
    for index in target.len {
        if target[index] == '?' {
            return FieldValue {
                present: true,
                value: target[index + 1..]
            };
        }
    }
    return FieldValue {
    };
}

fn raw_query_pairs(raw: u8[:], options: QueryOptions = QueryOptions {
    }) -> RawQueryIterator {
    return RawQueryIterator {
        input: raw,
        separators: options.separators,
        pending: raw.len > 0,
        pairs_max: options.pairs_max,
        error: if !valid_query_options(options) {
            QueryError.InvalidOptions
        } else if raw.len > options.input_bytes_max {
            QueryError.InputLimit
        } else {
            QueryError.None
        },
        ..
    };
}

fn query_separator(byte: u8, separators: u8[:]) -> bool {
    for separator in separators {
        if byte == separator {
            return true;
        }
    }
    return false;
}

fn next_raw_query(iterator: RawQueryIterator&) -> RawQueryItem {
    if iterator.error != QueryError.None {
        return RawQueryItem {
            error: iterator.error,
            ..
        };
    }
    if !iterator.pending {
        return RawQueryItem {
        };
    }
    if iterator.count >= iterator.pairs_max {
        iterator.error = QueryError.PairLimit;
        return RawQueryItem {
            error: iterator.error,
            ..
        };
    }
    let start = iterator.cursor;
    var end = start;
    while end < iterator.input.len && !query_separator(iterator.input[end], iterator.separators) {
        end += 1;
    }
    var equals = start;
    while equals < end && iterator.input[equals] != '=' {
        equals += 1;
    }
    let value_start = if equals < end {
        equals + 1
    } else {
        end
    };
    iterator.pending = end < iterator.input.len;
    iterator.cursor = if iterator.pending {
        end + 1
    } else {
        end
    };
    iterator.count += 1;
    let key = iterator.input[start..equals];
    let value = iterator.input[value_start..end];
    return RawQueryItem {
        present: true,
        pair: QueryPair {
            key: key,
            value: value,
            raw_key: key,
            raw_value: value,
            has_equals: equals < end
        },
        ..
    };
}

// Raw-key presence remains separate from decoded lookup, even for malformed query escapes.
fn raw_key_present(raw: u8[:], name: u8[:], options: QueryOptions = QueryOptions {
    }) -> QueryPresence {
    var iterator = raw_query_pairs(raw, options);
    var found = false;
    while iterator.pending || iterator.error != QueryError.None {
        let item = next_raw_query(iterator);
        if item.error != QueryError.None {
            return QueryPresence {
                error: item.error,
                ..
            };
        }
        if !item.present {
            return QueryPresence {
                present: found,
                ..
            };
        }
        found = found || item.pair.raw_key == name;
    }
    return QueryPresence {
        present: found,
        ..
    };
}
