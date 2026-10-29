// Static admission permits directories and root; regular open_file keeps its stricter contract.
namespace silly;

import.file_types;
import.files;
import.static_native;

struct StaticLookupOptions {
    gzip: bool = false,
    freshness_ms: i64 = 0,
}
struct StaticFileInfo {
    ok: bool,
    directory: bool = false,
    gzip: bool = false,
    error: i32 = 0,
}

fn open_static_file(executor: FileExecutor, root: FileRoot, path: u8[:],
    options: StaticLookupOptions = StaticLookupOptions {
    }) -> FileOpenResult {
    let token = silly_files_static_open(executor.epoch, root.fd, path,
        if options.gzip {
            1
        } else {
            0
        }, options.freshness_ms);
    return FileOpenResult {
        ok: token > 0,
        file: OwnedFile {
            epoch: if token > 0 {
                executor.epoch
            } else {
                0
            },
            token: if token > 0 {
                token
            } else {
                0
            },
            chunk_bytes: if token > 0 {
                executor.chunk_bytes
            } else {
                0
            },
        },
        error: if token < 0 {
            (-token)as i32
        } else {
            0
        },
    };
}

fn static_file_info(file: OwnedFile) -> StaticFileInfo {
    let raw = silly_files_static_info(file.epoch, file.token);
    return StaticFileInfo {
        ok: raw > 0,
        directory: raw == 2,
        gzip: raw == 3,
        error: if raw < 0 {
            (-raw)as i32
        } else {
            0
        },
    };
}

fn list_file_directory(file: OwnedFile, entries_max: i64 = 128, bytes_max: i64 = 32768) -> FileOperation {
    return file_operation(silly_files_list(file.epoch, file.token, entries_max, bytes_max));
}

fn take_directory_listing(file: OwnedFile, output: u8[:]) -> FileOperation {
    return file_operation(silly_files_listing(file.epoch, file.token, output));
}

fn static_file_retryable(error: i32) -> bool {
    return silly_files_retryable(error) != 0;
}
