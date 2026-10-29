// Directory records and output are bounded; names never become markup or path separators.
namespace silly;

import std;

struct DirectoryName {
    start: i64,
    length: i64,
    directory: bool,
}

fn directory_append(out: u8[>..]&, value: u8[:], cap: i64) -> bool {
    if out.len > cap || value.len > cap - out.len {
        return false;
    }
    out.append(value);
    return true;
}

fn directory_escape(out: u8[>..]&, value: u8[:], cap: i64) -> bool {
    for byte in value {
        let escaped = match byte {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            '\'' => "&#39;",
            _ => "",
        };
        if escaped.len > 0 {
            if !directory_append(out, escaped, cap) {
                return false;
            }
        } else {
            if out.len >= cap {
                return false;
            }
            out.push(byte);
        }
    }
    return true;
}

fn directory_unreserved(byte: u8) -> bool {
    return (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z')
        || (byte >= '0' && byte <= '9') || byte == '-' || byte == '_' || byte == '.' || byte == '~';
}

fn directory_percent(out: u8[>..]&, byte: u8, cap: i64) -> bool {
    if cap - out.len < 3 {
        return false;
    }
    let hex = "0123456789ABCDEF";
    out.push('%');
    out.push(hex[byte / 16]);
    out.push(hex[byte % 16]);
    return true;
}

fn directory_segment(out: u8[>..]&, name: u8[:], cap: i64) -> bool {
    for byte in name {
        if directory_unreserved(byte) {
            if out.len >= cap {
                return false;
            }
            out.push(byte);
        } else if !directory_percent(out, byte, cap) {
            return false;
        }
    }
    return true;
}

fn directory_names(records: u8[:], names: DirectoryName[>..]&) -> bool {
    if records.len > 32768 {
        return false;
    }
    var at: i64 = 0;
    while at < records.len {
        if names.len >= 128 || records.len - at < 3 {
            return false;
        }
        let kind = records[at];
        let length: i64 = records[at + 1] + records[at + 2]as i64 * 256;
        at += 3;
        if (kind != 1 && kind != 2) || length < 1 || length > 255 || length > records.len - at {
            return false;
        }
        let name = records[at..at + length];
        if name == "." || name == ".." {
            return false;
        }
        for byte in name {
            if byte == 0 || byte == '/' || byte == '\\' {
                return false;
            }
        }
        names.push(DirectoryName {
                start: at,
                length: length,
                directory: kind == 2
            });
        at += length;
    }
    return true;
}

fn directory_before(records: u8[:], left: DirectoryName, right: DirectoryName) -> bool {
    let length = min(left.length, right.length);
    for index in length {
        let a = records[left.start + index];
        let b = records[right.start + index];
        if a != b {
            return a < b;
        }
    }
    return left.length < right.length;
}

fn directory_sort(records: u8[:], names: DirectoryName[>..]&) {
    for index in names.len {
        var at = index;
        while at > 0 && directory_before(records, names[at], names[at - 1]) {
            let prior = names[at - 1];
            names[at - 1] = names[at];
            names[at] = prior;
            at -= 1;
        }
    }
}

fn directory_entry(out: u8[>..]&, records: u8[:], entry: DirectoryName,
    path: u8[:], cap: i64) -> bool {
    let name = records[entry.start..entry.start + entry.length];
    var href: u8[>..] = [];
    if !directory_append(href, path, cap) || !directory_segment(href, name, cap) {
        return false;
    }
    if entry.directory && !directory_append(href, "/", cap) {
        return false;
    }
    return directory_append(out, "<li><a href=\"", cap) && directory_escape(out, href, cap)
        && directory_append(out, "\">", cap) && directory_escape(out, name, cap)
        && (!entry.directory || directory_append(out, "/", cap))
        && directory_append(out, "</a></li>\n", cap);
}

fn directory_listing(out: u8[>..]&, records: u8[:], path: u8[:], cap: i64 = 32768) -> ResponseError {
    if cap < 0 || cap > 32768 || out.len > cap {
        return ResponseError.OutputLimit;
    }
    if path.len < 1 || path.len > 4096 || path[0] != '/' || path[path.len - 1] != '/'
        || (path.len > 1 && path[1] == '/') {
        return ResponseError.InvalidHeader;
    }
    for byte in path {
        if byte == '?' {
            return ResponseError.InvalidHeader;
        }
    }
    var encoded_path: u8[>..] = [];
    let encoded = directory_redirect(encoded_path, path);
    if encoded != ResponseError.None {
        return encoded;
    }
    var names: DirectoryName[>..] = [];
    if !directory_names(records, names) {
        return ResponseError.Application;
    }
    directory_sort(records, names);
    var body: u8[>..] = [];
    let available = cap - out.len;
    if !directory_append(body, "<!DOCTYPE html>\n<html><head><title>Directory listing for ", available)
        || !directory_escape(body, path, available)
        || !directory_append(body, "</title></head><body><h2>Directory listing for ", available)
        || !directory_escape(body, path, available)
        || !directory_append(body, "</h2><ul>\n", available) {
        return ResponseError.OutputLimit;
    }
    for entry in names {
        if !directory_entry(body, records, entry, encoded_path, available) {
            return ResponseError.OutputLimit;
        }
    }
    if !directory_append(body, "</ul></body></html>\n", available) {
        return ResponseError.OutputLimit;
    }
    out.append(body);
    return ResponseError.None;
}

// Preserve existing escapes; encode unsafe bytes without turning a path into a network-path URL.
fn directory_redirect(out: u8[>..]&, target: u8[:], cap: i64 = 8192) -> ResponseError {
    if cap < 0 || cap > 8192 || out.len > cap {
        return ResponseError.OutputLimit;
    }
    var query = target.len;
    for index in target.len {
        if target[index] == '?' {
            query = index;
            break;
        }
    }
    if query < 1 || query > 4096 || target.len - query > 4097 || target[0] != '/'
        || (query > 1 && target[1] == '/') {
        return ResponseError.InvalidHeader;
    }
    var value: u8[>..] = [];
    let available = cap - out.len;
    var at: i64 = 0;
    while at <= target.len {
        if at == query && target[query - 1] != '/' {
            if !directory_append(value, "/", available) {
                return ResponseError.OutputLimit;
            }
        }
        if at == target.len {
            break;
        }
        let byte = target[at];
        if byte == '%' && url_escape_valid(target, at) {
            if !directory_append(value, target[at..at + 3], available) {
                return ResponseError.OutputLimit;
            }
            at += 3;
            continue;
        }
        if directory_unreserved(byte) || byte == '/' || (at >= query && byte >= 33 && byte <= 126
            && byte != '#' && byte != '%' && byte != '\\' && byte != '"' && byte != '<' && byte != '>') {
            if value.len >= available {
                return ResponseError.OutputLimit;
            }
            value.push(byte);
        } else if !directory_percent(value, byte, available) {
            return ResponseError.OutputLimit;
        }
        at += 1;
    }
    out.append(value);
    return ResponseError.None;
}
