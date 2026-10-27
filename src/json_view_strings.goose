// Strict Unicode validation is independent of application raw-body JSON parsing.
namespace silly;

import json;

import.json_types;

struct JsonStringScan {
    end: i64 = 0,
    bytes: i64 = 0,
    escaped: bool = false,
    error: JsonError = JsonError.None,
}

fn json_valid_utf8(bytes: u8[:]) -> bool {
    var at: i64 = 0;
    while at < bytes.len {
        let lead = bytes[at];
        if lead < 128 {
            at += 1;
            continue;
        }
        var width: i64 = 0;
        if lead >= 194 && lead <= 223 {
            width = 2;
        } else if lead >= 224 && lead <= 239 {
            width = 3;
        } else if lead >= 240 && lead <= 244 {
            width = 4;
        } else {
            return false;
        }
        if width > bytes.len - at {
            return false;
        }
        for offset in 1..width {
            if bytes[at + offset] < 128 || bytes[at + offset] > 191 {
                return false;
            }
        }
        let second = bytes[at + 1];
        if (lead == 224 && second < 160) || (lead == 237 && second > 159)
            || (lead == 240 && second < 144) || (lead == 244 && second > 143) {
            return false;
        }
        at += width;
    }
    return true;
}

fn json_hex4(text: u8[:], at: i64) -> i64 {
    if at < 0 || text.len - at < 4 {
        return -1;
    }
    var code: i64 = 0;
    for index in 4 {
        let digit = json::hex_digit(text[at + index]);
        if digit < 0 {
            return -1;
        }
        code = code * 16 + digit;
    }
    return code;
}

fn json_unicode_escape(text: u8[:], at: i64) -> i64, i64 {
    let code = json_hex4(text, at);
    if code < 0 || (code >= 0xDC00 && code <= 0xDFFF) {
        return -1, 0;
    }
    if code >= 0xD800 && code <= 0xDBFF {
        if text.len - at < 10 || text[at + 4] != '\\' || text[at + 5] != 'u' {
            return -1, 0;
        }
        let low = json_hex4(text, at + 6);
        if low < 0xDC00 || low > 0xDFFF {
            return -1, 0;
        }
        return 4, 10;
    }
    return if code < 128 {
        1
    } else if code < 2048 {
        2
    } else {
        3
    }, 4;
}

fn json_scan_string(text: u8[:], start: i64) -> JsonStringScan {
    var result = JsonStringScan {
        end: start,
        ..
    };
    if start < 0 || start >= text.len || text[start] != '"' {
        result.error = JsonError.InvalidString;
        return result;
    }
    var at = start + 1;
    while at < text.len {
        let byte = text[at];
        if byte == '"' {
            result.end = at + 1;
            if !json_valid_utf8(text[start + 1..at]) {
                result.error = JsonError.InvalidString;
            }
            return result;
        }
        if byte < 32 {
            break;
        }
        if byte == '\\' {
            result.escaped = true;
            if text.len - at < 2 {
                break;
            }
            let escaped = text[at + 1];
            if escaped == 'u' {
                let bytes, width = json_unicode_escape(text, at + 2);
                if bytes < 0 {
                    break;
                }
                result.bytes += bytes;
                at += width + 2;
                continue;
            }
            if escaped != '"' && escaped != '\\' && escaped != '/' && escaped != 'b'
                && escaped != 'f' && escaped != 'n' && escaped != 'r' && escaped != 't' {
                break;
            }
            at += 1;
        }
        result.bytes += 1;
        at += 1;
    }
    result.end = at;
    result.error = JsonError.InvalidString;
    return result;
}
