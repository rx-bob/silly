// Applications select the base/path/query; repeated query bytes are never reparsed or reordered.
namespace silly_client;

import std;

import.types;

fn proxy_target(out: u8[>..]&, base: u8[:], path: u8[:], query: u8[:] = "") -> ClientError {
    if out.len != 0 || base.len == 0 || base.len > 4096 || path.len > 4096 || query.len > 4096 {
        return ClientError.Invalid;
    }
    if !starts_with(base, "http://") && !starts_with(base, "https://") {
        return ClientError.Invalid;
    }
    let authority: i64 = if starts_with(base, "https://") {
        8
    } else {
        7
    };
    if base.len <= authority || base[authority] == '/' {
        return ClientError.Invalid;
    }
    if find(base, "?") >= 0 || find(base, "#") >= 0 || find(path, "?") >= 0 || find(path, "#") >= 0 {
        return ClientError.Invalid;
    }
    if !proxy_target_safe(base) || !proxy_target_safe(path) || !proxy_target_safe(query) {
        return ClientError.Invalid;
    }
    var end = base.len;
    while end > 0 && base[end - 1] == '/' {
        end -= 1;
    }
    var start: i64 = 0;
    while start < path.len && path[start] == '/' {
        start += 1;
    }
    let query_start: i64 = if query.len > 0 && query[0] == '?' {
        1
    } else {
        0
    };
    let extra = if query.len > 0 {
        1 + query.len - query_start
    } else {
        0
    };
    let size = end + 1 + path.len - start + extra;
    if size > 4096 {
        return ClientError.Limit;
    }
    out.append(base[..end]);
    out.push('/');
    out.append(path[start..]);
    if query.len > 0 {
        out.push('?');
        out.append(query[query_start..]);
    }
    return ClientError.None;
}

fn proxy_target_safe(value: u8[:]) -> bool {
    for byte in value {
        if byte <= 32 || byte == 127 || byte == '#' || byte == '\\' {
            return false;
        }
    }
    return true;
}
