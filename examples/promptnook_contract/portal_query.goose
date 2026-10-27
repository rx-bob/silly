// Source compatibility: decoded keys group by first occurrence, retaining each repeated value.
namespace promptnook_portal;

import silly from "../..";

import.portal_types;

fn select_environment(out: Prepared&, raw: u8[:]) {
    var scratch: u8[>..] = [];
    let pairs = silly::parse_query(raw, scratch, query_options());
    if pairs.error != silly::QueryError.None {
        out.error = PortalError.Limit;
        return;
    }
    let selected = silly::get(pairs, "environment");
    let present = silly::raw_key_present(raw, "environment", query_options());
    if selected.value.len > out.environment.cap - (if present.present {
            0
        } else {
            5
        }) {
        out.error = PortalError.Limit;
        return;
    }
    out.environment.append(selected.value);
    // Legacy has() uses the raw key while value() decodes it; preserve that observable distinction.
    if !present.present {
        out.environment.append("axiom");
    }
}

fn filtered_query(out: u8[>..]&, raw: u8[:]) -> PortalError {
    var scratch: u8[>..] = [];
    let pairs = silly::parse_query(raw, scratch, query_options("&;"));
    if pairs.error != silly::QueryError.None {
        return PortalError.Limit;
    }
    for index in pairs.entries.len {
        let pair = pairs.entries[index];
        if (pair.raw_key.len == 0 && pair.raw_value.len == 0 && !pair.has_equals)
            || silly::query_key_equal(pair.key, "environment", silly::KeyMatch.AsciiIgnoreCase) {
            continue;
        }
        var earlier = false;
        for before in index {
            let previous = pairs.entries[before];
            if previous.key == pair.key && (previous.raw_key.len != 0
                || previous.raw_value.len != 0 || previous.has_equals) {
                earlier = true;
            }
        }
        if earlier {
            continue;
        }
        for value in pairs.entries {
            if value.key != pair.key || (value.raw_key.len == 0 && value.raw_value.len == 0 && !value.has_equals) {
                continue;
            }
            if !append_pair(out, pair.key, value.value) {
                return PortalError.Limit;
            }
        }
    }
    return PortalError.None;
}

fn append_pair(out: u8[>..]&, key: u8[:], value: u8[:]) -> bool {
    if out.len > 0 {
        if out.len == 4096 {
            return false;
        }
        out.push('&');
    }
    if !append_form(out, key) || out.len == 4096 {
        return false;
    }
    out.push('=');
    return append_form(out, value);
}

fn append_form(out: u8[>..]&, value: u8[:]) -> bool {
    let hex = "0123456789ABCDEF";
    for byte in value {
        let literal = (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z')
            || (byte >= '0' && byte <= '9') || byte == '-' || byte == '_' || byte == '.' || byte == '~';
        let size: i64 = if literal || byte == ' ' {
            1
        } else {
            3
        };
        if size > 4096 - out.len {
            return false;
        }
        if literal {
            out.push(byte);
        } else if byte == ' ' {
            out.push('+');
        } else {
            out.push('%');
            out.push(hex[byte / 16]);
            out.push(hex[byte % 16]);
        }
    }
    return true;
}
