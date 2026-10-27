// Direct JSON output borrows an existing bounded byte owner.
namespace silly;

import.json_types;
import.json_view_strings;

struct JsonWriteOptions {
    depth_max: i64 = 64,
    collection_max: i64 = 1024,
    aliases: const JsonAlias[:] = EMPTY_JSON_ALIASES,
}
struct JsonWriter {
    output: u8[>..]&,
    cap: i64,
    options: JsonWriteOptions = JsonWriteOptions {
    },
    depth: i64 = 0,
    items: i64 = 0,
    checked: bool = false,
    error: JsonError = JsonError.None,
}
struct JsonNull {
}

fn json_write_fail(writer: JsonWriter&, error: JsonError) -> JsonError {
    if writer.error == JsonError.None {
        writer.error = error;
    }
    return writer.error;
}

fn json_write_valid(writer: JsonWriter&) -> bool {
    if writer.cap < 0 || writer.output.len > writer.cap || writer.options.depth_max < 0
        || writer.options.depth_max > 256 || writer.options.collection_max < 0 {
        json_write_fail(writer, JsonError.InvalidOptions);
    }
    if !writer.checked && writer.error == JsonError.None {
        writer.checked = true;
        if !json_write_aliases_valid(writer.options.aliases) {
            json_write_fail(writer, JsonError.InvalidOptions);
        }
    }
    return writer.error == JsonError.None;
}

fn json_emit(writer: JsonWriter&, bytes: u8[:]) {
    if !json_write_valid(writer) {
        return;
    }
    if bytes.len > writer.cap - writer.output.len {
        json_write_fail(writer, JsonError.OutputLimit);
    } else {
        writer.output.append(bytes);
    }
}

fn json_open(writer: JsonWriter&, bytes: u8[:], count: i64) -> bool {
    if !json_write_valid(writer) {
        return false;
    }
    if writer.depth >= writer.options.depth_max {
        json_write_fail(writer, JsonError.DepthLimit);
        return false;
    }
    if count > writer.options.collection_max - writer.items {
        json_write_fail(writer, JsonError.CollectionLimit);
        return false;
    }
    writer.items += count;
    writer.depth += 1;
    json_emit(writer, bytes);
    if writer.error != JsonError.None {
        writer.depth -= 1;
        return false;
    }
    return true;
}

fn json_close(writer: JsonWriter&, bytes: u8[:]) {
    writer.depth -= 1;
    json_emit(writer, bytes);
}

fn json_wire_key(options: JsonWriteOptions, name: u8[:]) -> const u8[:] {
    for alias in options.aliases {
        if alias.field == name {
            return alias.wire;
        }
    }
    return name;
}

fn json_write_aliases_valid(aliases: JsonAlias[:]) -> bool {
    for alias, index in aliases {
        if alias.field.len == 0 || !json_valid_utf8(alias.wire) {
            return false;
        }
        for other in aliases[..index] {
            if alias.field == other.field || alias.wire == other.wire {
                return false;
            }
        }
    }
    return true;
}
