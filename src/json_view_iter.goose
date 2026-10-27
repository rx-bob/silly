namespace silly;

import json;

import.json_view;

fn json_object(value: JsonValue) -> JsonObjectIterator {
    return JsonObjectIterator {
        value: value,
        error: if value.kind == JsonKind.Object {
            JsonError.None
        } else {
            JsonError.Type
        },
        ..
    };
}

fn json_array(value: JsonValue) -> JsonArrayIterator {
    return JsonArrayIterator {
        value: value,
        error: if value.kind == JsonKind.Array {
            JsonError.None
        } else {
            JsonError.Type
        },
        ..
    };
}

fn json_after_child(raw: u8[:], cursor: i64&, close: u8) -> bool {
    cursor = json::skip_space(raw, cursor);
    if cursor >= raw.len {
        return true;
    }
    if raw[cursor] == close {
        return true;
    }
    cursor += 1;
    return false;
}

fn next_json_member(it: JsonObjectIterator&) -> JsonMember {
    if it.error != JsonError.None {
        return JsonMember {
            error: it.error,
            ..
        };
    }
    if it.done {
        return JsonMember {
        };
    }
    it.cursor = json::skip_space(it.value.raw, it.cursor);
    if it.cursor >= it.value.raw.len || it.value.raw[it.cursor] == '}' {
        it.done = true;
        return JsonMember {
        };
    }
    let key = json_scan_string(it.value.raw, it.cursor);
    if key.error != JsonError.None {
        return JsonMember {
            error: key.error,
            ..
        };
    }
    var name: const u8[:] = it.value.raw[it.cursor + 1..key.end - 1];
    if key.escaped {
        if key.bytes > it.value.decoded.len - it.decoded_cursor {
            return JsonMember {
                error: JsonError.InvalidString,
                ..
            };
        }
        name = it.value.decoded[it.decoded_cursor..it.decoded_cursor + key.bytes];
        it.decoded_cursor += key.bytes;
    }
    it.cursor = json::skip_space(it.value.raw, key.end) + 1;
    it.cursor = json::skip_space(it.value.raw, it.cursor);
    let child = json_subvalue(it.value, it.cursor, it.decoded_cursor);
    if child.error != JsonError.None {
        return JsonMember {
            error: child.error,
            ..
        };
    }
    it.cursor += child.value.raw.len;
    it.decoded_cursor += child.value.decoded.len;
    it.done = json_after_child(it.value.raw, it.cursor, '}');
    return JsonMember {
        present: true,
        key: name,
        value: child.value,
        ..
    };
}

fn next_json_element(it: JsonArrayIterator&) -> JsonElement {
    if it.error != JsonError.None {
        return JsonElement {
            error: it.error,
            ..
        };
    }
    if it.done {
        return JsonElement {
        };
    }
    it.cursor = json::skip_space(it.value.raw, it.cursor);
    if it.cursor >= it.value.raw.len || it.value.raw[it.cursor] == ']' {
        it.done = true;
        return JsonElement {
        };
    }
    let child = json_subvalue(it.value, it.cursor, it.decoded_cursor);
    if child.error != JsonError.None {
        return child;
    }
    it.cursor += child.value.raw.len;
    it.decoded_cursor += child.value.decoded.len;
    it.done = json_after_child(it.value.raw, it.cursor, ']');
    return child;
}

fn json_member(value: JsonValue, key: u8[:], duplicates: JsonDuplicate = JsonDuplicate.Reject) -> JsonMember {
    var it = json_object(value);
    var found = false;
    var start: i64 = 0;
    var size: i64 = 0;
    var decoded_start: i64 = 0;
    var decoded_size: i64 = 0;
    var kind = JsonKind.Null;
    loop {
        let member = next_json_member(it);
        if member.error != JsonError.None {
            return JsonMember {
                error: member.error,
                ..
            };
        }
        if !member.present {
            break;
        }
        if member.key != key {
            continue;
        }
        if found && duplicates == JsonDuplicate.Reject {
            return JsonMember {
                error: JsonError.Duplicate,
                ..
            };
        }
        if !found || duplicates == JsonDuplicate.Last {
            start = member.value.offset - value.offset;
            size = member.value.raw.len;
            decoded_size = member.value.decoded.len;
            decoded_start = it.decoded_cursor - decoded_size;
            kind = member.value.kind;
        }
        found = true;
    }
    if !found {
        return JsonMember {
        };
    }
    return JsonMember {
        present: true,
        key: key,
        value: JsonValue {
            offset: value.offset + start,
            raw: value.raw[start..start + size],
            decoded: value.decoded[decoded_start..decoded_start + decoded_size],
            kind: kind,
            limits: value.limits,
        },
        ..
    };
}
