// Specialization writes nested structures directly without an intermediate document string.
namespace silly;

import.json_types;
import.json_writer_scalars;
import.json_writer_types;

fn write_json_array<T>(writer: JsonWriter&, values: T[:]) -> JsonError {
    if !json_open(writer, "[", values.len) {
        return writer.error;
    }
    for value, index in values {
        if index != 0 {
            json_emit(writer, ",");
        }
        write_json(writer, value);
        if writer.error != JsonError.None {
            break;
        }
    }
    json_close(writer, "]");
    return writer.error;
}

fn json_default_field<T>(writer: JsonWriter&, name: u8[:], value: T&) {
    write_json(writer, value);
}

fn write_json_object_with<T, F>(writer: JsonWriter&, value: T&) -> JsonError {
    var count: i64 = 0;
    const for <N, A> in fields<T> {
        count += 1;
    }
    if !json_object_keys_valid<T>(writer.options) {
        return json_write_fail(writer, JsonError.InvalidOptions);
    }
    if !json_open(writer, "{", count) {
        return writer.error;
    }
    var index: i64 = 0;
    const for <N, A> in fields<T> {
        if writer.error == JsonError.None {
            if index != 0 {
                json_emit(writer, ",");
            }
            write_json(writer, json_wire_key(writer.options, N));
            json_emit(writer, ":");
            if writer.error == JsonError.None {
                F(writer, N, value.A);
            }
            index += 1;
        }
    }
    json_close(writer, "}");
    return writer.error;
}

fn write_json<T>(writer: JsonWriter&, value: T&) -> JsonError {
    return write_json_object_with(writer, value, json_default_field);
}

fn json_object_keys_valid<T>(options: JsonWriteOptions) -> bool {
    var valid = true;
    const for <N, A> in fields<T> {
        const for <M, B> in fields<T> {
            if N != M && json_wire_key(options, N) == json_wire_key(options, M) {
                valid = false;
            }
        }
    }
    return valid;
}
