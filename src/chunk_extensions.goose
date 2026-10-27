// Strict token/quoted-string chunk extensions; metadata is validated then discarded.
namespace silly;

import.headers;

fn chunk_hex(byte: u8) -> i64 {
    var digit: i64 = -1;
    if byte >= '0' && byte <= '9' {
        digit = byte - '0';
    } else if byte >= 'a' && byte <= 'f' {
        digit = byte - 'a' + 10;
    } else if byte >= 'A' && byte <= 'F' {
        digit = byte - 'A' + 10;
    }
    return digit;
}

fn chunk_space(line: u8[:], cursor: i64) -> i64 {
    var next = cursor;
    while next < line.len && (line[next] == ' ' || line[next] == '\t') {
        next += 1;
    }
    return next;
}

fn chunk_token_end(line: u8[:], cursor: i64) -> i64 {
    var end = cursor;
    while end < line.len && header_token_byte(line[end]) {
        end += 1;
    }
    return end;
}

fn chunk_quoted_end(line: u8[:], cursor: i64) -> i64 {
    var next = cursor + 1;
    while next < line.len {
        let byte = line[next];
        next += 1;
        if byte == '"' {
            return next;
        }
        if byte == '\\' {
            if next == line.len {
                return -1;
            }
            let escaped = line[next];
            if escaped != '\t' && (escaped < 32 || escaped == 127) {
                return -1;
            }
            next += 1;
        } else if byte != '\t' && (byte < 32 || byte == 127) {
            return -1;
        }
    }
    return -1;
}

fn valid_chunk_extensions(line: u8[:], start: i64) -> bool {
    var cursor = start;
    while cursor < line.len {
        cursor = chunk_space(line, cursor);
        if cursor == line.len || line[cursor] != ';' {
            return false;
        }
        cursor = chunk_space(line, cursor + 1);
        let end = chunk_token_end(line, cursor);
        if end == cursor {
            return false;
        }
        cursor = end;
        let after_space = chunk_space(line, cursor);
        if after_space < line.len && line[after_space] == '=' {
            cursor = chunk_space(line, after_space + 1);
            if cursor == line.len {
                return false;
            }
            let value_end = if line[cursor] == '"' {
                chunk_quoted_end(line, cursor)
            } else {
                chunk_token_end(line, cursor)
            };
            if value_end <= cursor {
                return false;
            }
            cursor = value_end;
        }
    }
    return true;
}
