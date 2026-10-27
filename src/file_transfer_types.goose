// Owned file transfer state; bounded multipart framing never retains handler borrows.
namespace silly;

import.file_multipart;
import.file_types;

enum FileTransferError {
    None,
    Native,
    InvalidRange,
    UnexpectedEnd,
    OutputLimit,
    InvalidState,
}
struct FileTransfer {
    file: OwnedFile = OwnedFile {
    },
    offset: i64 = 0,
    length: i64 = -1,
    poll_interval_ms: i64 = 1,
    size: i64 = -1,
    position: i64 = 0,
    remaining: i64 = 0,
    initialized: bool = false,
    reading: bool = false,
    closed: bool = false,
    error: FileTransferError = FileTransferError.None,
    system_error: i32 = 0,
    static_metadata: bool = false,
    metadata_published: bool = false,
    conditional: bool = false,
    none_match_present: bool = false,
    none_match_valid: bool = true,
    none_match: u8[..4096] = [],
    modified_since: u8[..128] = [],
    configured_etag: u8[..256] = [],
    range_enabled: bool = false,
    ranges_max: i64 = 16,
    range_value: u8[..4096] = [],
    if_range_present: bool = false,
    if_range_valid: bool = true,
    if_range: u8[..256] = [],
    content_type: u8[..512] = [],
    multipart: FileMultipart = FileMultipart {
    },
}
