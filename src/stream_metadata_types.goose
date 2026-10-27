// A callback may fill this owned record only before a deferred response is committed.
namespace silly;

import.headers;

struct StreamMetadata {
    ready: bool = false,
    close: bool = false,
    replace_headers: bool = false,
    header_fields: HeaderField[..128] = [],
    header_bytes: u8[..16384] = [],
    status: i32 = 200,
    representation_length: i64 = -1,
    suppress_content_range: bool = false,
    suppress_content_encoding: bool = false,
    content_encoding: u8[..16] = [],
    vary_accept_encoding: bool = false,
    location: u8[..8192] = [],
    content_range: u8[..128] = [],
    content_type: u8[..512] = [],
    accept_ranges: bool = false,
    etag: u8[..256] = [],
    last_modified: u8[..29] = [],
}
