// Application-owned compatibility copy for synchronous contiguous-request consumers.
// This is decoded-body HTTP/1.1, not the original wire image: framing headers are replaced.
// Header spelling, order, duplicate fields and wire whitespace survive; trailers do not.
namespace promptnook_adapters;

import silly from "../..";

import std;

enum SnapshotError {
    None,
    Limit,
    InvalidRequest,
    BodyUnavailable,
}

struct Snapshot {
    error: SnapshotError = SnapshotError.None,
    bytes: u8[>..] = [],
}

const SNAPSHOT_BYTES_MAX: i64 = 131072;

fn snapshot_framing(name: u8[:]) -> bool {
    return silly::header_name_equal(name, "Content-Length")
        || silly::header_name_equal(name, "Transfer-Encoding")
        || silly::header_name_equal(name, "Trailer")
        || silly::header_name_equal(name, "Expect");
}

fn snapshot_append(out: Snapshot&, bytes: u8[:], limit: i64) {
    if out.error != SnapshotError.None {
        return;
    }
    if bytes.len > limit - out.bytes.len {
        out.error = SnapshotError.Limit;
        out.bytes.clear();
        return;
    }
    out.bytes.append(bytes);
}

fn snapshot_headers(out: Snapshot&, request: silly::Request, limit: i64) {
    for field in request.headers {
        if !silly::valid_header_name(field.name) || !silly::valid_header_value(field.value) {
            out.error = SnapshotError.InvalidRequest;
            out.bytes.clear();
            return;
        }
        if !snapshot_framing(field.name) {
            snapshot_append(out, field.name, limit);
            snapshot_append(out, ":", limit);
            snapshot_append(out, field.value, limit);
            snapshot_append(out, "\r\n", limit);
        }
    }
}

fn snapshot_body(out: Snapshot&, request: silly::Request, body: u8[:], limit: i64) {
    snapshot_append(out, request.method, limit);
    snapshot_append(out, " ", limit);
    snapshot_append(out, request.target, limit);
    snapshot_append(out, " HTTP/1.1\r\n", limit);
    snapshot_headers(out, request, limit);
    snapshot_append(out, str("Content-Length: ", body.len, "\r\n\r\n"), limit);
    if out.error != SnapshotError.None {
        return;
    }
    var fields: silly::HeaderView[>..] = [];
    let parsed = silly::parse_head(out.bytes, fields, silly::Limits {
            header_count_max: 129,
            ..
        });
    if parsed.result != silly::HeadResult.Complete || parsed.head_bytes != out.bytes.len
        || parsed.method != request.method || parsed.target != request.target {
        out.error = SnapshotError.InvalidRequest;
        out.bytes.clear();
        return;
    }
    snapshot_append(out, body, limit);
}

// One extra bounded copy, owned until the legacy call returns. Never retain its borrowed slices.
// The input must be a validated request with Host and a fully collected decoded body.
fn snapshot(request: silly::Request, limit: i64 = SNAPSHOT_BYTES_MAX) -> Snapshot {
    var out = Snapshot {
    };
    if limit < 0 || limit > SNAPSHOT_BYTES_MAX || request.headers.len > 128 {
        out.error = SnapshotError.Limit;
        return out;
    }
    match request.body_state {
        Buffered body => {
            if body.bytes.len > limit {
                out.error = SnapshotError.Limit;
            } else {
                snapshot_body(out, request, body.bytes, limit);
            }
        },
        _ => {
            out.error = SnapshotError.BodyUnavailable;
        },
    }
    return out;
}
