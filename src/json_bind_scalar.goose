// Strict scalar conversion does not coerce nulls, strings, fractions or out-of-range integers.
namespace silly;

import json;
import std;

import.json_bind_types;
import.json_types;
import.json_view;

fn json_bind_value(value: JsonValue, seed: bool, options: JsonBindOptions, state: JsonBindState&) -> bool {
    if value.kind != JsonKind.Bool {
        json_bind_fail(state, JsonError.Type);
        return seed;
    }
    return value.raw == "true";
}

fn json_bind_value(value: JsonValue, seed: u8[:], options: JsonBindOptions, state: JsonBindState&) -> const u8[:] {
    if value.kind != JsonKind.String {
        json_bind_fail(state, JsonError.Type);
        return seed;
    }
    let field = json_string(value);
    if !field.present {
        json_bind_fail(state, JsonError.InvalidString);
        return seed;
    }
    return field.value;
}

fn json_bind_magnitude(value: JsonValue, maximum: u64, negative: bool, state: JsonBindState&) -> u64 {
    if value.kind != JsonKind.Number {
        json_bind_fail(state, JsonError.Type);
        return 0;
    }
    let raw = value.raw;
    let start: i64 = if negative {
        1
    } else {
        0
    };
    if raw.len <= start {
        json_bind_fail(state, JsonError.InvalidNumber);
        return 0;
    }
    var result: u64 = 0;
    for index in start..raw.len {
        let byte = raw[index];
        if byte < '0' || byte > '9' {
            json_bind_fail(state, JsonError.InvalidNumber);
            return 0;
        }
        let digit: u64 = byte - '0';
        if result > maximum / 10 || (result == maximum / 10 && digit > maximum % 10) {
            json_bind_fail(state, JsonError.InvalidNumber);
            return 0;
        }
        result = result * 10 + digit;
    }
    return result;
}

fn json_bind_signed(value: JsonValue, minimum: i64, maximum: i64, state: JsonBindState&) -> i64 {
    let negative = value.raw.len > 0 && value.raw[0] == '-';
    let cap: u64 = if negative {
        (-(minimum + 1))as u64 + 1
    } else {
        maximum as u64
    };
    let magnitude = json_bind_magnitude(value, cap, negative, state);
    if negative && magnitude > 0 {
        return -((magnitude - 1)as i64) - 1;
    }
    return magnitude as i64;
}

fn json_bind_unsigned(value: JsonValue, maximum: u64, state: JsonBindState&) -> u64 {
    return json_bind_magnitude(value, maximum, false, state);
}

fn json_bind_value(value: JsonValue, seed: i8, options: JsonBindOptions, state: JsonBindState&) -> i8 {
    return json_bind_signed(value, -128, 127, state)as i8;
}

fn json_bind_value(value: JsonValue, seed: i16, options: JsonBindOptions, state: JsonBindState&) -> i16 {
    return json_bind_signed(value, -32768, 32767, state)as i16;
}

fn json_bind_value(value: JsonValue, seed: i32, options: JsonBindOptions, state: JsonBindState&) -> i32 {
    return json_bind_signed(value, -2147483648, 2147483647, state)as i32;
}

fn json_bind_value(value: JsonValue, seed: i64, options: JsonBindOptions, state: JsonBindState&) -> i64 {
    return json_bind_signed(value, -9223372036854775807 - 1, 9223372036854775807, state);
}

fn json_bind_value(value: JsonValue, seed: u8, options: JsonBindOptions, state: JsonBindState&) -> u8 {
    return json_bind_unsigned(value, 255, state)as u8;
}

fn json_bind_value(value: JsonValue, seed: u16, options: JsonBindOptions, state: JsonBindState&) -> u16 {
    return json_bind_unsigned(value, 65535, state)as u16;
}

fn json_bind_value(value: JsonValue, seed: u32, options: JsonBindOptions, state: JsonBindState&) -> u32 {
    return json_bind_unsigned(value, 4294967295, state)as u32;
}

fn json_bind_value(value: JsonValue, seed: u64, options: JsonBindOptions, state: JsonBindState&) -> u64 {
    return json_bind_unsigned(value, 18446744073709551615, state);
}

fn json_bind_float(value: JsonValue, state: JsonBindState&) -> f64 {
    if value.kind != JsonKind.Number {
        json_bind_fail(state, JsonError.Type);
        return 0.0;
    }
    let number = json::scan_number(value.raw, 0);
    if number.end != value.raw.len || number.value != number.value || number.value - number.value != 0.0 {
        json_bind_fail(state, JsonError.InvalidNumber);
        return 0.0;
    }
    return number.value;
}

fn json_bind_value(value: JsonValue, seed: f64, options: JsonBindOptions, state: JsonBindState&) -> f64 {
    return json_bind_float(value, state);
}

fn json_bind_value(value: JsonValue, seed: f32, options: JsonBindOptions, state: JsonBindState&) -> f32 {
    let number = json_bind_float(value, state);
    if number > 3.4028234663852886e38 || number < - 3.4028234663852886e38 {
        json_bind_fail(state, JsonError.InvalidNumber);
        return 0.0;
    }
    return number as f32;
}
