// Typed binding is opt-in; named policies make absence and defaults explicit.
namespace silly;

import.json_types;
import.json_view_strings;

enum JsonPresence {
    Missing,
    Null,
    Present
}
enum JsonUnknown {
    Reject,
    Ignore
}
enum JsonFieldPolicy {
    Required,
    Defaulted,
    Nullable,
    Optional
}
struct JsonFieldRule {
    field: const u8[:],
    policy: JsonFieldPolicy = JsonFieldPolicy.Required,
}
const EMPTY_JSON_FIELD_RULES: JsonFieldRule[0] = [];
struct JsonBindOptions {
    limits: JsonLimits = JsonLimits {
    },
    aliases: const JsonAlias[:] = EMPTY_JSON_ALIASES,
    fields: const JsonFieldRule[:] = EMPTY_JSON_FIELD_RULES,
    unknown_fields: JsonUnknown = JsonUnknown.Reject,
    duplicates: JsonDuplicate = JsonDuplicate.Reject,
}
struct JsonBinding<T> {
    source: JsonValue = JsonValue {
    },
    options: JsonBindOptions = JsonBindOptions {
    },
    value: T = default<T>(),
    error: JsonError = JsonError.None,
    error_at: i64 = 0,
}
struct JsonBindState {
    error: JsonError = JsonError.None,
    error_at: i64 = 0,
    current_offset: i64 = 0,
}

fn json_bind_fail(state: JsonBindState&, error: JsonError) {
    if state.error == JsonError.None {
        state.error = error;
        state.error_at = state.current_offset;
    }
}

fn json_bind_key(name: u8[:], options: JsonBindOptions) -> const u8[:] {
    for alias in options.aliases {
        if alias.field == name {
            return alias.wire;
        }
    }
    return name;
}

fn valid_json_bind_options(options: JsonBindOptions) -> bool {
    if !valid_json_limits(options.limits) || options.aliases.len > options.limits.collection_max
        || options.fields.len > options.limits.collection_max {
        return false;
    }
    for index in options.aliases.len {
        let alias = options.aliases[index];
        if alias.field.len == 0 || !json_valid_utf8(alias.field) || !json_valid_utf8(alias.wire) {
            return false;
        }
        for previous in index {
            let other = options.aliases[previous];
            if other.field == alias.field || other.wire == alias.wire {
                return false;
            }
        }
    }
    for index in options.fields.len {
        if options.fields[index].field.len == 0 || !json_valid_utf8(options.fields[index].field) {
            return false;
        }
        for previous in index {
            if options.fields[previous].field == options.fields[index].field {
                return false;
            }
        }
    }
    return true;
}

fn json_field_policy(name: u8[:], options: JsonBindOptions) -> JsonFieldPolicy {
    for rule in options.fields {
        if rule.field == name {
            return rule.policy;
        }
    }
    return JsonFieldPolicy.Required;
}
