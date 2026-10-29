// Request-local sorted lookup metadata retains exact source offsets and wire identity.
namespace silly;

import.headers;

struct HeaderIndexEntry {
    field_index: i64,
    source: HeaderField,
}

const EMPTY_HEADER_INDEX: HeaderIndexEntry[0] = [];

// The parser calls this once per validated field; its count cap bounds insertion work/storage.
fn index_header(index: HeaderIndexEntry[>..]&, fields: HeaderView[:], field_index: i64, source: HeaderField) {
    assert(field_index >= 0);
    assert(field_index < fields.len);
    let entry = HeaderIndexEntry {
        field_index: field_index,
        source: source,
    };
    var position = index.len;
    index.push(entry);
    while position > 0 {
        let previous = index[position - 1];
        let order = header_name_order(fields[previous.field_index].name, fields[field_index].name);
        if order < 0 || (order == 0 && previous.field_index <= field_index) {
            break;
        }
        index[position] = previous;
        position -= 1;
    }
    index[position] = entry;
}

fn header_name_order(left: u8[:], right: u8[:]) -> i32 {
    let shared = if left.len < right.len {
        left.len
    } else {
        right.len
    };
    for index in shared {
        let a = header_lower(left[index]);
        let b = header_lower(right[index]);
        if a != b {
            return if a < b {
                -1
            } else {
                1
            };
        }
    }
    return if left.len == right.len {
        0
    } else if left.len < right.len {
        -1
    } else {
        1
    };
}

// upper=false finds the first equal name; upper=true finds the first greater name.
fn header_index_bound(index: HeaderIndexEntry[:], fields: HeaderView[:], name: u8[:], upper: bool) -> i64 {
    var start: i64 = 0;
    var end = index.len;
    while start < end {
        let middle = start + (end - start) / 2;
        let field = fields[index[middle].field_index];
        let order = header_name_order(field.name, name);
        if order < 0 || (upper && order == 0) {
            start = middle + 1;
        } else {
            end = middle;
        }
    }
    return start;
}
