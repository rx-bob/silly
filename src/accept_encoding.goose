// Integer quality values keep content negotiation bounded and deterministic.
namespace silly;

import.file_ranges;
import.headers;

struct EncodingPreference {
    valid: bool = true,
    gzip: i32 = 0,
    identity: i32 = 1000,
}
struct EncodingWeights {
    gzip: i32 = -1,
    identity: i32 = -1,
    wildcard: i32 = -1,
}

fn encoding_quality(value: u8[:]) -> i32 {
    if value.len == 0 || value.len > 5 || (value[0] != '0' && value[0] != '1') {
        return -1;
    }
    if value.len == 1 {
        return if value[0] == '1' {
            1000
        } else {
            0
        };
    }
    if value[1] != '.' {
        return -1;
    }
    var weight: i32 = if value[0] == '1' {
        1000
    } else {
        0
    };
    var factor: i32 = 100;
    for index in value.len - 2 {
        let byte = value[index + 2];
        if byte < '0' || byte > '9' || (value[0] == '1' && byte != '0') {
            return -1;
        }
        weight += (byte - '0') * factor;
        factor /= 10;
    }
    return weight;
}

fn encoding_weight(existing: i32, incoming: i32) -> i32 {
    return if existing < 0 || incoming < existing {
        incoming
    } else {
        existing
    };
}

fn encoding_item(weights: EncodingWeights&, item: u8[:]) -> bool {
    var separator = item.len;
    for index in item.len {
        if item[index] == ';' {
            separator = index;
            break;
        }
    }
    let name = range_trim(item[..separator]);
    if !valid_header_name(name) {
        return false;
    }
    var quality: i32 = 1000;
    if separator < item.len {
        let parameter = range_trim(item[separator + 1..]);
        if parameter.len < 2 || (parameter[0] != 'q' && parameter[0] != 'Q') || parameter[1] != '=' {
            return false;
        }
        quality = encoding_quality(parameter[2..]);
        if quality < 0 {
            return false;
        }
    }
    if header_name_equal(name, "gzip") {
        weights.gzip = encoding_weight(weights.gzip, quality);
    } else if header_name_equal(name, "identity") {
        weights.identity = encoding_weight(weights.identity, quality);
    } else if name == "*" {
        weights.wildcard = encoding_weight(weights.wildcard, quality);
    }
    return true;
}

// Duplicate codings use the lowest quality: explicit exclusions cannot be bypassed.
// Malformed lists disable gzip but retain any parsed identity exclusion.
fn parse_accept_encoding(value: u8[:], present: bool = true) -> EncodingPreference {
    var result = EncodingPreference {
    };
    if !present || value.len == 0 {
        return result;
    }
    if value.len > 4096 {
        result.valid = false;
        return result;
    }
    var weights = EncodingWeights {
    };
    var start: i64 = 0;
    while start < value.len {
        var end = start;
        while end < value.len && value[end] != ',' {
            end += 1;
        }
        let item = range_trim(value[start..end]);
        if item.len > 0 && !encoding_item(weights, item) {
            result.valid = false;
        }
        start = end + 1;
    }
    result.identity = if weights.identity >= 0 {
        weights.identity
    } else if weights.wildcard == 0 {
        0
    } else {
        1000
    };
    if result.valid {
        result.gzip = if weights.gzip >= 0 {
            weights.gzip
        } else if weights.wildcard >= 0 {
            weights.wildcard
        } else {
            0
        };
    }
    return result;
}
