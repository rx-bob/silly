// Immutable snapshot captured by fstat on the descriptor used for all subsequent reads.
namespace silly;

import std;

import.file_native;
import.file_types;

struct FileMetadata {
    size: i64 = -1,
    modified_seconds: i64 = -1,
    modified_nanoseconds: i64 = 0,
    device: u64 = 0,
    inode: u64 = 0,
    observed_seconds: i64 = 0,
}
struct FileMetadataResult {
    ok: bool,
    metadata: FileMetadata = FileMetadata {
    },
    error: i32 = 0,
}
struct FileValidator {
    last_modified_strong: bool = false,
    etag: u8[..256] = [],
}

fn file_metadata(file: OwnedFile) -> FileMetadataResult {
    var fields: i64[6] = [0; 6];
    let result = silly_files_metadata(file.epoch, file.token, fields);
    if result < 0 {
        return FileMetadataResult {
            ok: false,
            error: (-result)as i32,
            ..
        };
    }
    return FileMetadataResult {
        ok: true,
        metadata: FileMetadata {
            size: fields[0],
            modified_seconds: fields[1],
            modified_nanoseconds: fields[2],
            device: fields[3]as u64,
            inode: fields[4]as u64,
            observed_seconds: fields[5],
        },
        ..
    };
}

// Stat-derived validators are weak: metadata does not prove byte identity under in-place writes.
fn default_file_validator(metadata: FileMetadata) -> FileValidator {
    var result = FileValidator {
    };
    result.etag.append(str("W/\"", metadata.device, "-", metadata.inode, "-", metadata.size,
        "-", metadata.modified_seconds, "-", metadata.modified_nanoseconds, "\""));
    return result;
}
