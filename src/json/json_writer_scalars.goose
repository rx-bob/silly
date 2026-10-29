// Scalar formatting uses bounded tokens; strings write escaped pieces directly to output.
namespace silly;

import json;
import std;

import.json_types;
import.json_view_strings;
import.json_writer_types;

fn write_json(writer: JsonWriter&, value: JsonNull) -> JsonError {
    json_emit(writer, "null");
    return writer.error;
}

fn write_json(writer: JsonWriter&, value: bool) -> JsonError {
    json_emit(writer, if value {
            "true"
        } else {
            "false"
        });
    return writer.error;
}

fn write_json(writer: JsonWriter&, value: i64) -> JsonError {
    var text: u8[>..] = [];
    format(text, value);
    json_emit(writer, text);
    return writer.error;
}

fn write_json(writer: JsonWriter&, value: u64) -> JsonError {
    var text: u8[>..] = [];
    format(text, value);
    json_emit(writer, text);
    return writer.error;
}

fn write_json(writer: JsonWriter&, value: f64) -> JsonError {
    if value != value || value - value != 0.0 {
        return json_write_fail(writer, JsonError.InvalidNumber);
    }
    var text: u8[>..] = [];
    json::format_number(text, value);
    json_emit(writer, text);
    return writer.error;
}

fn write_json(writer: JsonWriter&, value: i8) -> JsonError {
    return write_json(writer, value as i64);
}

fn write_json(writer: JsonWriter&, value: i16) -> JsonError {
    return write_json(writer, value as i64);
}

fn write_json(writer: JsonWriter&, value: i32) -> JsonError {
    return write_json(writer, value as i64);
}

fn write_json(writer: JsonWriter&, value: u8) -> JsonError {
    return write_json(writer, value as u64);
}

fn write_json(writer: JsonWriter&, value: u16) -> JsonError {
    return write_json(writer, value as u64);
}

fn write_json(writer: JsonWriter&, value: u32) -> JsonError {
    return write_json(writer, value as u64);
}

fn write_json(writer: JsonWriter&, value: f32) -> JsonError {
    return write_json(writer, value as f64);
}

fn json_escape_byte(writer: JsonWriter&, byte: u8) {
    if byte == '"' {
        json_emit(writer, "\\\"");
    } else if byte == '\\' {
        json_emit(writer, "\\\\");
    } else if byte == '\n' {
        json_emit(writer, "\\n");
    } else if byte == '\r' {
        json_emit(writer, "\\r");
    } else if byte == '\t' {
        json_emit(writer, "\\t");
    } else if byte == 8 {
        json_emit(writer, "\\b");
    } else if byte == 12 {
        json_emit(writer, "\\f");
    } else {
        let digits = "0123456789abcdef";
        let escaped: u8[6] = ['\\', 'u', '0', '0', digits[byte >> 4], digits[byte & 15]];
        json_emit(writer, escaped);
    }
}

fn write_json(writer: JsonWriter&, value: u8[:]) -> JsonError {
    if !json_write_valid(writer) {
        return writer.error;
    }
    if !json_valid_utf8(value) {
        return json_write_fail(writer, JsonError.InvalidString);
    }
    json_emit(writer, "\"");
    var start: i64 = 0;
    for byte, index in value {
        if byte < 32 || byte == '"' || byte == '\\' {
            json_emit(writer, value[start..index]);
            json_escape_byte(writer, byte);
            start = index + 1;
        }
    }
    json_emit(writer, value[start..]);
    json_emit(writer, "\"");
    return writer.error;
}
