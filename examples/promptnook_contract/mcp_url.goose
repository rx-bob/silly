// Source: http_posix.c:210. Application URL normalization strips userinfo and fragments.
namespace promptnook_mcp;

import std;

struct NormalizedUrl {
    ok: bool = false,
    value: u8[..4096] = [],
}

fn url_space(byte: u8) -> bool {
    return byte == ' ' || byte == '\t' || byte == '\r' || byte == '\n';
}

fn normalize_url(input: u8[:]) -> NormalizedUrl {
    var result = NormalizedUrl {
    };
    if input.len > 4096 {
        return result;
    }
    var start: i64 = 0;
    var end = input.len;
    while start < end && url_space(input[start]) {
        start += 1;
    }
    while end > start && url_space(input[end - 1]) {
        end -= 1;
    }
    let source = input[start..end];
    let separator = find(source, "://");
    if separator != 4 && separator != 5 {
        return result;
    }
    var scheme: u8[..5] = [];
    for byte in source[..separator] {
        scheme.push(url_lower(byte));
    }
    if scheme != "http" && scheme != "https" {
        return result;
    }
    var authority_end = separator + 3;
    var host_start = authority_end;
    while authority_end < source.len && source[authority_end] != '/' && source[authority_end] != '?'
        && source[authority_end] != '#' {
        if source[authority_end] == '@' {
            host_start = authority_end + 1;
        }
        authority_end += 1;
    }
    if host_start >= authority_end {
        return result;
    }
    for byte in source[host_start..authority_end] {
        if byte <= 32 || byte == '\\' {
            return result;
        }
    }
    var fragment = authority_end;
    while fragment < source.len && source[fragment] != '#' {
        fragment += 1;
    }
    let root = authority_end == fragment || source[authority_end] == '?' || source[authority_end] == '#';
    let size = scheme.len + 3 + authority_end - host_start + fragment - authority_end + (if root {
            1
        } else {
            0
        });
    if size > result.value.cap {
        return result;
    }
    result.value.append(scheme);
    result.value.append("://");
    for byte in source[host_start..authority_end] {
        result.value.push(url_lower(byte));
    }
    if root {
        result.value.push('/');
    }
    result.value.append(source[authority_end..fragment]);
    result.ok = true;
    return result;
}

fn url_lower(byte: u8) -> u8 {
    return if byte >= 'A' && byte <= 'Z' {
        byte + 32
    } else {
        byte
    };
}
