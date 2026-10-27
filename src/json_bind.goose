// Reflection expands required fields; custom readers compose the same checked operations.
namespace silly;

import.json_bind_scalar;
import.json_bind_types;
import.json_types;
import.json_view;
import.json_view_scan;

fn bind_json<T>(value: JsonValue, options: JsonBindOptions = JsonBindOptions {
    }) -> JsonBinding<T> {
    return bind_json_with<T>(value, options, json_bind_value);
}

fn bind_json_with<T, F>(value: JsonValue, options: JsonBindOptions = JsonBindOptions {
    }) -> JsonBinding<T> {
    var state = JsonBindState {
    };
    let seed = default<T>();
    if !valid_json_bind_options(options) {
        return JsonBinding<T> {
            error: JsonError.InvalidOptions,
            ..
        };
    }
    json_binding_preflight(value, options, state);
    if state.error != JsonError.None {
        return JsonBinding<T> {
            error: state.error,
            error_at: state.error_at,
            ..
        };
    }
    let result = F(value, seed, options, state);
    if state.error != JsonError.None {
        return JsonBinding<T> {
            error: state.error,
            error_at: state.error_at,
            ..
        };
    }
    return JsonBinding<T> {
        source: value,
        options: options,
        value: result,
        error: state.error,
        error_at: state.error_at
    };
}

fn json_bind_value<T>(value: JsonValue, seed: T, options: JsonBindOptions, state: JsonBindState&) -> T {
    if state.error != JsonError.None {
        return seed;
    }
    if value.kind != JsonKind.Object {
        json_bind_fail(state, JsonError.Type);
        return seed;
    }
    json_check_members(value, seed, options, state);
    return T {
        const for <N,
        field> in fields<T> {
            field: json_read_field(value, N, seed.field, options, state),
        }
    };
}

fn json_check_members<T>(value: JsonValue, seed: T, options: JsonBindOptions, state: JsonBindState&) {
    const for <N, A> in fields<T> {
        const for <M, B> in fields<T> {
            if N != M && json_bind_key(N, options) == json_bind_key(M, options) {
                json_bind_fail(state, JsonError.InvalidOptions);
            }
        }
    }
    var iterator = json_object(value);
    var member = next_json_member(iterator);
    while member.present && state.error == JsonError.None {
        state.current_offset = member.value.offset;
        var known = false;
        var matches: i64 = 0;
        const for <N, A> in fields<T> {
            if json_bind_key(N, options) == member.key {
                known = true;
                matches += 1;
            }
        }
        if matches > 1 {
            json_bind_fail(state, JsonError.InvalidOptions);
        }
        if options.duplicates == JsonDuplicate.Reject {
            let duplicate = json_member(value, member.key, JsonDuplicate.Reject);
            if duplicate.error != JsonError.None {
                json_bind_fail(state, duplicate.error);
            }
        }
        if !known && options.unknown_fields == JsonUnknown.Reject {
            json_bind_fail(state, JsonError.Unknown);
        }
        member = next_json_member(iterator);
    }
    if member.error != JsonError.None {
        json_bind_fail(state, member.error);
    }
}

fn json_read_field<T>(value: JsonValue, name: u8[:], seed: T,
    options: JsonBindOptions, state: JsonBindState&) -> T {
    return json_read_field_with(value, name, seed, options, state, json_bind_value);
}

fn json_read_field_with<T, F>(value: JsonValue, name: u8[:], seed: T,
    options: JsonBindOptions, state: JsonBindState&) -> T {
    if state.error != JsonError.None {
        return seed;
    }
    state.current_offset = value.offset;
    let member = json_member(value, json_bind_key(name, options), options.duplicates);
    if member.error != JsonError.None {
        json_bind_fail(state, member.error);
        return seed;
    }
    let policy = json_field_policy(name, options);
    if !member.present {
        if policy == JsonFieldPolicy.Defaulted || policy == JsonFieldPolicy.Optional {
            return seed;
        }
        json_bind_fail(state, JsonError.Required);
        return seed;
    }
    state.current_offset = member.value.offset;
    if member.value.kind == JsonKind.Null
        && (policy == JsonFieldPolicy.Nullable || policy == JsonFieldPolicy.Optional) {
        return seed;
    }
    return F(member.value, seed, options, state);
}

fn json_field_presence<T>(bound: JsonBinding<T>, name: u8[:]) -> JsonPresence {
    let member = json_member(bound.source, json_bind_key(name, bound.options), bound.options.duplicates);
    if !member.present || member.error != JsonError.None {
        return JsonPresence.Missing;
    }
    return if member.value.kind == JsonKind.Null {
        JsonPresence.Null
    } else {
        JsonPresence.Present
    };
}

// Custom field readers preserve exact fixed array shape without size-generic language support.
fn json_read_array<A>(value: JsonValue, seed: A, options: JsonBindOptions, state: JsonBindState&) -> A {
    var result = seed;
    if value.kind != JsonKind.Array {
        json_bind_fail(state, JsonError.Type);
        return result;
    }
    var iterator = json_array(value);
    var item = next_json_element(iterator);
    var count: i64 = 0;
    while item.present && state.error == JsonError.None {
        if count >= result.len {
            json_bind_fail(state, JsonError.CollectionLimit);
            return result;
        }
        let stable = json_subvalue(value, item.value.offset - value.offset,
            iterator.decoded_cursor - item.value.decoded.len).value;
        state.current_offset = stable.offset;
        result[count] = json_bind_value(stable, result[count], options, state);
        count += 1;
        item = next_json_element(iterator);
    }
    if item.error != JsonError.None {
        json_bind_fail(state, item.error);
    }
    if count != result.len {
        json_bind_fail(state, JsonError.Type);
    }
    return result;
}

// A is an inline bounded array. E gives its element seed without inspecting an empty array.
fn json_read_list<A, E>(value: JsonValue, seed: A, element_seed: E,
    options: JsonBindOptions, state: JsonBindState&) -> A {
    var result = default<A>();
    if value.kind != JsonKind.Array {
        json_bind_fail(state, JsonError.Type);
        return result;
    }
    var iterator = json_array(value);
    var item = next_json_element(iterator);
    while item.present && state.error == JsonError.None {
        if result.len >= result.cap {
            json_bind_fail(state, JsonError.CollectionLimit);
            return result;
        }
        let stable = json_subvalue(value, item.value.offset - value.offset,
            iterator.decoded_cursor - item.value.decoded.len).value;
        state.current_offset = stable.offset;
        result.push(json_bind_value(stable, element_seed, options, state));
        item = next_json_element(iterator);
    }
    if item.error != JsonError.None {
        json_bind_fail(state, item.error);
    }
    return result;
}

fn json_binding_preflight(value: JsonValue, options: JsonBindOptions, state: JsonBindState&) {
    state.current_offset = value.offset;
    if value.raw.len > options.limits.body_bytes_max {
        json_bind_fail(state, JsonError.BodyLimit);
        return;
    }
    var scan = JsonScan {
        text: value.raw,
        limits: options.limits,
        ..
    };
    let kind = json_scan_value(scan, 0);
    json_scan_space(scan);
    if scan.error != JsonError.None {
        state.current_offset = value.offset + scan.error_at;
        json_bind_fail(state, scan.error);
    } else if scan.pos != value.raw.len || kind != value.kind {
        json_bind_fail(state, JsonError.Syntax);
    } else if scan.decoded_bytes != value.decoded.len {
        json_bind_fail(state, JsonError.InvalidString);
    }
}
