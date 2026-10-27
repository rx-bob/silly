// A callback may fill this owned record only before a deferred response is committed.
namespace silly;

struct StreamMetadata {
    ready: bool = false,
    status: i32 = 200,
    representation_length: i64 = -1,
    content_range: u8[..128] = [],
    content_type: u8[..512] = [],
    accept_ranges: bool = false,
    etag: u8[..256] = [],
    last_modified: u8[..29] = [],
}
