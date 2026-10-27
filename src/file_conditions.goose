// Entity-tag comparison is weak for GET/HEAD; malformed lists never produce a cache hit.
namespace silly;

struct TagCondition {
    valid: bool = false,
    matched: bool = false,
}

fn valid_etag(tag: u8[:]) -> bool {
    return tag.len > 0 && entity_tag_end(tag, 0) == tag.len;
}

fn valid_entity_tag(tag: u8[:]) -> bool {
    return valid_etag(tag);
}

fn entity_tag_end(value: u8[:], start: i64) -> i64 {
    var at = start;
    if at < 0 || at >= value.len {
        return -1;
    }
    if value.len - at >= 2 && value[at] == 'W' && value[at + 1] == '/' {
        at += 2;
    }
    if at >= value.len || value[at] != '"' {
        return -1;
    }
    at += 1;
    while at < value.len {
        let byte = value[at];
        if byte == '"' {
            return at + 1;
        }
        if byte < 0x21 || byte == 0x7f {
            return -1;
        }
        at += 1;
    }
    return -1;
}

fn tag_space(value: u8[:], start: i64) -> i64 {
    var at = start;
    while at < value.len && (value[at] == ' ' || value[at] == '\t') {
        at += 1;
    }
    return at;
}

fn opaque_tag_start(value: u8[:], start: i64) -> i64 {
    return if value.len - start >= 2 && value[start] == 'W' && value[start + 1] == '/' {
        start + 2
    } else {
        start
    };
}

fn if_none_match(value: u8[:], current: u8[:]) -> TagCondition {
    var at = tag_space(value, 0);
    if at < value.len && value[at] == '*' {
        let valid = tag_space(value, at + 1) == value.len;
        return TagCondition {
            valid: valid,
            matched: valid
        };
    }
    var found = false;
    var matched = false;
    let usable = valid_etag(current);
    while at < value.len {
        // RFC list recipients tolerate empty elements; require at least one actual entity-tag.
        if value[at] == ',' {
            at = tag_space(value, at + 1);
            continue;
        }
        let end = entity_tag_end(value, at);
        if end < 0 {
            return TagCondition {
            };
        }
        found = true;
        if usable && value[opaque_tag_start(value, at)..end] == current[opaque_tag_start(current, 0)..] {
            matched = true;
        }
        at = tag_space(value, end);
        if at == value.len {
            break;
        }
        if value[at] != ',' {
            return TagCondition {
            };
        }
        at = tag_space(value, at + 1);
    }
    return TagCondition {
        valid: found,
        matched: found && matched
    };
}
