// Guarded extractors return fixed-size views; metadata iteration never allocates.
namespace silly;

import.query;
import.query_decode;
import.query_raw;
import.query_types;
import.request;

fn parse_query_view(raw: u8[:], scratch: u8[>..]&, options: QueryOptions = QueryOptions {
    }) -> QueryView {
    let start = scratch.len;
    let error = prepare_query_scratch(raw, scratch, options);
    if error != QueryError.None {
        return QueryView {
            error: error,
            ..
        };
    }
    return QueryView {
        raw: raw,
        decoded: scratch[start..],
        options: options,
        count: measure_query(raw, options).count,
        ..
    };
}

fn query_iterator(view: QueryView) -> QueryIterator {
    var raw = raw_query_pairs(view.raw, view.options);
    if view.error != QueryError.None {
        raw.error = view.error;
    }
    return QueryIterator {
        raw: raw,
        decoded: view.decoded,
        options: view.options,
        ..
    };
}

fn next_query_pair(iterator: QueryIterator&) -> RawQueryItem {
    var item = next_raw_query(iterator.raw);
    if !item.present {
        return item;
    }
    item.pair.key = query_piece_view(item.pair.raw_key, iterator.decoded,
        iterator.decoded_cursor, iterator.options);
    item.pair.value = query_piece_view(item.pair.raw_value, iterator.decoded,
        iterator.decoded_cursor, iterator.options);
    return item;
}

fn get(view: QueryView, name: u8[:]) -> FieldValue {
    if view.error != QueryError.None {
        return FieldValue {
        };
    }
    return query_first_view(view.raw, view.decoded, name, view.options);
}

fn query_values(view: QueryView, name: u8[:]) -> QueryValues {
    return QueryValues {
        from_view: true,
        iterator: query_iterator(view),
        name: name,
        ..
    };
}

fn next_query_view_value(values: QueryValues&) -> FieldValue {
    while values.iterator.raw.pending || values.iterator.raw.error != QueryError.None {
        let item = next_query_pair(values.iterator);
        if !item.present {
            return FieldValue {
            };
        }
        if item.pair.key == values.name {
            return FieldValue {
                present: true,
                value: item.pair.value
            };
        }
    }
    return FieldValue {
    };
}

fn without_query_keys(view: QueryView, keys: (const u8[:])[:],
    match_key: KeyMatch = KeyMatch.Exact) -> QueryPairs {
    var result = QueryPairs {
        error: view.error,
        pairs_max: view.options.pairs_max,
        ..
    };
    if result.error != QueryError.None {
        return result;
    }
    var iterator = raw_query_pairs(view.raw, view.options);
    var cursor: i64 = 0;
    while iterator.pending {
        let item = next_raw_query(iterator);
        if !item.present {
            result.error = item.error;
            return result;
        }
        let key = query_piece_view(item.pair.raw_key, view.decoded, cursor, view.options);
        let value = query_piece_view(item.pair.raw_value, view.decoded, cursor, view.options);
        if !query_key_filtered(key, keys, match_key) {
            result.entries.push(QueryPair {
                    key: key,
                    value: value,
                    raw_key: item.pair.raw_key,
                    raw_value: item.pair.raw_value,
                    has_equals: item.pair.has_equals,
                });
        }
    }
    return result;
}
