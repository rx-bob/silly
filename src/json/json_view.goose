// Fully validated JSON views preserve input bytes and decode strings into caller scratch once.
namespace silly;

import json;

import.json_types;
import.json_view_iter;
import.json_view_scan;
import.json_view_strings;

fn json_decode_strings(text: u8[:], scratch: u8[>..]&) {
    var at: i64 = 0;
    while at < text.len {
        if text[at] != '"' {
            at += 1;
            continue;
        }
        let token = json_scan_string(text, at);
        if token.escaped {
            let decoded, ok = json::decode_string(text, at + 1, token.end - 1, scratch);
            assert(ok);
        }
        at = token.end;
    }
}

fn parse_json(input: u8[:], scratch: u8[>..]&, limits: JsonLimits = JsonLimits {
    }) -> JsonDocument {
    if !valid_json_limits(limits) {
        return JsonDocument {
            error: JsonError.InvalidOptions,
            ..
        };
    }
    if input.len > limits.body_bytes_max {
        return JsonDocument {
            error: JsonError.BodyLimit,
            ..
        };
    }
    var scan = JsonScan {
        text: input,
        limits: limits,
        ..
    };
    json_scan_space(scan);
    let start = scan.pos;
    let kind = json_scan_value(scan, 0);
    let end = scan.pos;
    json_scan_space(scan);
    if scan.error == JsonError.None && scan.pos != input.len {
        json_scan_fail(scan, JsonError.Syntax);
    }
    if scan.error != JsonError.None {
        return JsonDocument {
            error: scan.error,
            error_at: scan.error_at,
            ..
        };
    }
    if scratch.len > limits.decoded_bytes_max || scan.decoded_bytes > limits.decoded_bytes_max - scratch.len {
        return JsonDocument {
            error: JsonError.ScratchLimit,
            ..
        };
    }
    let decoded_start = scratch.len;
    json_decode_strings(input, scratch);
    return JsonDocument {
        value: JsonValue {
            offset: start,
            raw: input[start..end],
            decoded: scratch[decoded_start..],
            kind: kind,
            limits: limits
        },
        ..
    };
}

fn json_string(value: JsonValue) -> FieldValue {
    if value.kind != JsonKind.String {
        return FieldValue {
        };
    }
    let string = json_scan_string(value.raw, 0);
    if string.error != JsonError.None {
        return FieldValue {
        };
    }
    if string.escaped {
        if string.bytes > value.decoded.len {
            return FieldValue {
            };
        }
        return FieldValue {
            present: true,
            value: value.decoded[..string.bytes]
        };
    }
    return FieldValue {
        present: true,
        value: value.raw[1..string.end - 1]
    };
}

fn json_subvalue(parent: JsonValue, start: i64, decoded_start: i64) -> JsonElement {
    var scan = JsonScan {
        text: parent.raw,
        pos: start,
        limits: parent.limits,
        ..
    };
    json_scan_space(scan);
    let value_start = scan.pos;
    let kind = json_scan_value(scan, 0);
    if scan.error != JsonError.None {
        return JsonElement {
            error: scan.error,
            ..
        };
    }
    if decoded_start < 0 || decoded_start > parent.decoded.len
        || scan.decoded_bytes > parent.decoded.len - decoded_start {
        return JsonElement {
            error: JsonError.InvalidString,
            ..
        };
    }
    return JsonElement {
        present: true,
        value: JsonValue {
            offset: parent.offset + value_start,
            raw: parent.raw[value_start..scan.pos],
            decoded: parent.decoded[decoded_start..decoded_start + scan.decoded_bytes],
            kind: kind,
            limits: parent.limits,
        },
        ..
    };
}
