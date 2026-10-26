// Header access never rewrites wire bytes or interprets application identity/authentication.
namespace silly;

import.header_index;
import.headers;
import.request;

enum HeaderValueMode {
    Trimmed,
    Raw,
    Wire,
}

struct HeaderValues {
    fields: const HeaderView[:],
    index: const HeaderIndexEntry[:],
    name: const u8[:],
    cursor: i64,
    end: i64,
    mode: HeaderValueMode,
}

// Parsed requests use the sorted index; manually constructed requests retain ordered-view lookup.
fn header_values(request: Request, name: u8[:], mode: HeaderValueMode = HeaderValueMode.Trimmed) -> HeaderValues {
    var start: i64 = 0;
    var end = request.headers.len;
    if request.header_index.len != 0 {
        start = header_index_bound(request.header_index, request.headers, name, false);
        end = header_index_bound(request.header_index, request.headers, name, true);
    }
    return HeaderValues {
        fields: request.headers,
        index: request.header_index,
        name: name,
        cursor: start,
        end: end,
        mode: mode,
    };
}

// Each present result consumes one field in wire order, including empty values.
fn next_header(values: HeaderValues&) -> FieldValue {
    if values.cursor >= values.end {
        return FieldValue {
        };
    }
    var field_index: i64 = -1;
    if values.index.len != 0 {
        field_index = values.index[values.cursor].field_index;
        values.cursor += 1;
    } else {
        field_index = find_header(values.fields, values.name, values.cursor);
        values.cursor = if field_index < 0 {
            values.end
        } else {
            field_index + 1
        };
    }
    if field_index < 0 {
        return FieldValue {
        };
    }
    return FieldValue {
        present: true,
        value: header_value_view(values.fields[field_index].value, values.mode),
    };
}

fn header_value_view(value: u8[:], mode: HeaderValueMode) -> const u8[:] {
    var start: i64 = 0;
    var end = value.len;
    if mode != HeaderValueMode.Wire {
        while start < end && (value[start] == ' ' || value[start] == '\t') {
            start += 1;
        }
    }
    if mode == HeaderValueMode.Trimmed {
        while end > start && (value[end - 1] == ' ' || value[end - 1] == '\t') {
            end -= 1;
        }
    }
    return value[start..end];
}

fn find_request_header(request: Request, name: u8[:]) -> i64 {
    if request.header_index.len == 0 {
        return find_header(request.headers, name);
    }
    let position = header_index_bound(request.header_index, request.headers, name, false);
    if position >= request.header_index.len {
        return -1;
    }
    let field_index = request.header_index[position].field_index;
    return if header_name_equal(request.headers[field_index].name, name) {
        field_index
    } else {
        -1
    };
}

fn request_header_value(request: Request, name: u8[:], mode: HeaderValueMode) -> FieldValue {
    let field_index = find_request_header(request, name);
    if field_index < 0 {
        return FieldValue {
        };
    }
    return FieldValue {
        present: true,
        value: header_value_view(request.headers[field_index].value, mode),
    };
}

fn header(request: Request, name: u8[:]) -> FieldValue {
    return request_header_value(request, name, HeaderValueMode.Trimmed);
}

// Legacy raw mode removes leading SP/HTAB but preserves trailing SP/HTAB.
fn header_raw(request: Request, name: u8[:]) -> FieldValue {
    return request_header_value(request, name, HeaderValueMode.Raw);
}

// Exact bytes after the colon and before CRLF distinguish empty from whitespace-only.
fn header_wire(request: Request, name: u8[:]) -> FieldValue {
    return request_header_value(request, name, HeaderValueMode.Wire);
}
