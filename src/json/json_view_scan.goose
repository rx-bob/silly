// Grammar and resource preflight use fixed scanner state and explicitly bounded recursion.
namespace silly;

import json;

import.json_types;
import.json_view_strings;

struct JsonScan {
    text: const u8[:],
    limits: JsonLimits,
    pos: i64 = 0,
    items: i64 = 0,
    string_bytes: i64 = 0,
    decoded_bytes: i64 = 0,
    error: JsonError = JsonError.None,
    error_at: i64 = 0,
}
fn json_scan_fail(scan: JsonScan&, error: JsonError) {
    if scan.error == JsonError.None {
        scan.error = error;
        scan.error_at = scan.pos;
    }
}

fn json_scan_space(scan: JsonScan&) {
    scan.pos = json::skip_space(scan.text, scan.pos);
}

fn json_scan_text(scan: JsonScan&) {
    let text = json_scan_string(scan.text, scan.pos);
    if text.error != JsonError.None {
        json_scan_fail(scan, text.error);
        return;
    }
    if text.bytes > scan.limits.decoded_bytes_max - scan.string_bytes {
        json_scan_fail(scan, JsonError.ScratchLimit);
        return;
    }
    scan.string_bytes += text.bytes;
    if text.escaped {
        scan.decoded_bytes += text.bytes;
    }
    scan.pos = text.end;
}

fn json_scan_word(scan: JsonScan&, word: u8[:]) {
    if word.len > scan.text.len - scan.pos || scan.text[scan.pos..scan.pos + word.len] != word {
        json_scan_fail(scan, JsonError.Syntax);
        return;
    }
    scan.pos += word.len;
}

recursive fn json_scan_value(scan: JsonScan&, depth: i64) -> JsonKind {
    json_scan_space(scan);
    if scan.error != JsonError.None || scan.pos >= scan.text.len {
        json_scan_fail(scan, JsonError.Syntax);
        return JsonKind.Null;
    }
    let byte = scan.text[scan.pos];
    if byte == '"' {
        json_scan_text(scan);
        return JsonKind.String;
    }
    if byte == 'n' {
        json_scan_word(scan, "null");
        return JsonKind.Null;
    }
    if byte == 't' {
        json_scan_word(scan, "true");
        return JsonKind.Bool;
    }
    if byte == 'f' {
        json_scan_word(scan, "false");
        return JsonKind.Bool;
    }
    if byte == '[' || byte == '{' {
        if depth >= scan.limits.depth_max {
            json_scan_fail(scan, JsonError.DepthLimit);
        } else {
            json_scan_container(scan, depth, byte == '{');
        }
        return if byte == '{' {
            JsonKind.Object
        } else {
            JsonKind.Array
        };
    }
    if byte == '-' || (byte >= '0' && byte <= '9') {
        json_scan_number_token(scan);
        return JsonKind.Number;
    }
    json_scan_fail(scan, JsonError.Syntax);
    return JsonKind.Null;
}

recursive fn json_scan_container(scan: JsonScan&, depth: i64, object: bool) {
    scan.pos += 1;
    json_scan_space(scan);
    let close: u8 = if object {
        '}'
    } else {
        ']'
    };
    if scan.pos < scan.text.len && scan.text[scan.pos] == close {
        scan.pos += 1;
        return;
    }
    while scan.pos < scan.text.len && scan.error == JsonError.None {
        if object {
            json_scan_text(scan);
            if scan.error != JsonError.None {
                return;
            }
            json_scan_space(scan);
            if scan.pos >= scan.text.len || scan.text[scan.pos] != ':' {
                json_scan_fail(scan, JsonError.Syntax);
                return;
            }
            scan.pos += 1;
        }
        if scan.items >= scan.limits.collection_max {
            json_scan_fail(scan, JsonError.CollectionLimit);
            return;
        }
        scan.items += 1;
        json_scan_value(scan, depth + 1);
        if scan.error != JsonError.None {
            return;
        }
        json_scan_space(scan);
        if scan.pos >= scan.text.len {
            break;
        }
        let byte = scan.text[scan.pos];
        scan.pos += 1;
        if byte == close {
            return;
        }
        if byte != ',' {
            json_scan_fail(scan, JsonError.Syntax);
            return;
        }
        json_scan_space(scan);
    }
    json_scan_fail(scan, JsonError.Syntax);
}

// Validate JSON number grammar without converting or allocating arbitrary-precision digits.
fn json_scan_number_token(scan: JsonScan&) {
    let start = scan.pos;
    if scan.text[scan.pos] == '-' {
        scan.pos += 1;
    }
    let whole = scan.pos;
    while scan.pos < scan.text.len && scan.text[scan.pos] >= '0' && scan.text[scan.pos] <= '9' {
        scan.pos += 1;
    }
    if scan.pos == whole || (scan.pos - whole > 1 && scan.text[whole] == '0') {
        scan.pos = start;
        json_scan_fail(scan, JsonError.InvalidNumber);
        return;
    }
    if scan.pos < scan.text.len && scan.text[scan.pos] == '.' {
        scan.pos += 1;
        let fraction = scan.pos;
        while scan.pos < scan.text.len && scan.text[scan.pos] >= '0' && scan.text[scan.pos] <= '9' {
            scan.pos += 1;
        }
        if scan.pos == fraction {
            json_scan_fail(scan, JsonError.InvalidNumber);
            return;
        }
    }
    if scan.pos < scan.text.len && (scan.text[scan.pos] == 'e' || scan.text[scan.pos] == 'E') {
        scan.pos += 1;
        if scan.pos < scan.text.len && (scan.text[scan.pos] == '+' || scan.text[scan.pos] == '-') {
            scan.pos += 1;
        }
        let exponent = scan.pos;
        while scan.pos < scan.text.len && scan.text[scan.pos] >= '0' && scan.text[scan.pos] <= '9' {
            scan.pos += 1;
        }
        if scan.pos == exponent {
            json_scan_fail(scan, JsonError.InvalidNumber);
        }
    }
}
