// Startup roots and bounded asynchronous filesystem admission are independent of HTTP framing.
namespace silly;

import.file_native;
import.file_types;

fn start_file_executor(options: FileExecutorOptions = FileExecutorOptions {
    }) -> FileExecutorResult {
    let epoch = silly_files_start(options.workers, options.capacity, options.chunk_bytes);
    return FileExecutorResult {
        ok: epoch > 0,
        executor: FileExecutor {
            epoch: if epoch > 0 {
                epoch
            } else {
                0
            },
            chunk_bytes: if epoch > 0 {
                options.chunk_bytes
            } else {
                0
            },
        },
        error: if epoch < 0 {
            (-epoch)as i32
        } else {
            0
        },
    };
}

// Root opening is a startup operation. Request-time path walking runs on native workers.
fn open_file_root(path: u8[:]) -> FileRootResult {
    let raw = silly_files_root_open(path);
    return FileRootResult {
        ok: raw >= 0,
        root: FileRoot {
            fd: if raw >= 0 {
                raw as i32
            } else {
                -1
            }
        },
        error: if raw < 0 {
            (-raw)as i32
        } else {
            0
        },
    };
}

fn close_file_root(root: FileRoot&) -> FileOperation {
    if root.fd < 0 {
        return FileOperation {
            ok: true,
            ..
        };
    }
    let fd = root.fd;
    root.fd = -1;
    return file_operation(silly_files_root_close(fd));
}

// Admission copies the encoded relative path and pins the root. It never opens a data file inline.
fn open_file(executor: FileExecutor, root: FileRoot, path: u8[:]) -> FileOpenResult {
    let token = silly_files_open(executor.epoch, root.fd, path);
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

fn file_status(file: OwnedFile) -> FileResult {
    let raw = silly_files_status(file.epoch, file.token);
    if raw < 0 {
        return FileResult {
            status: FileStatus.Failed,
            error: (-raw)as i32,
            ..
        };
    }
    if raw == 0 {
        return FileResult {
            status: FileStatus.Pending,
            ..
        };
    }
    let size = silly_files_size(file.epoch, file.token);
    if size < 0 {
        return FileResult {
            status: FileStatus.Failed,
            error: (-size)as i32,
            ..
        };
    }
    return FileResult {
        status: if raw == 1 {
            FileStatus.Open
        } else if raw == 2 {
            FileStatus.Chunk
        } else {
            FileStatus.End
        },
        size: size,
        ..
    };
}

fn read_file(file: OwnedFile, offset: i64, count: i64) -> FileOperation {
    return file_operation(silly_files_read(file.epoch, file.token, offset, count));
}

fn take_file_chunk(file: OwnedFile, output: u8[:]) -> FileOperation {
    return file_operation(silly_files_take(file.epoch, file.token, output));
}

// Invalidate before cancellation. A worker closes only after any in-flight syscall returns.
fn close_file(file: OwnedFile&) -> FileOperation {
    if file.token == 0 {
        return FileOperation {
            ok: true,
            ..
        };
    }
    let epoch = file.epoch;
    let token = file.token;
    file = OwnedFile {
    };
    return file_operation(silly_files_cancel(epoch, token));
}

fn stop_file_executor(executor: FileExecutor) -> FileOperation {
    return file_operation(silly_files_stop(executor.epoch));
}

// A false completion retains the epoch and all pending resources. Retry from the shutdown owner.
fn finish_file_executor(executor: FileExecutor&) -> FileFinishResult {
    let raw = silly_files_finish(executor.epoch);
    if raw == 1 {
        executor = FileExecutor {
        };
    }
    return FileFinishResult {
        complete: raw == 1,
        error: if raw < 0 {
            (-raw)as i32
        } else {
            0
        },
    };
}

fn pending_file_operations(executor: FileExecutor) -> FileOperation {
    return file_operation(silly_files_pending(executor.epoch));
}

fn file_operation(raw: i64) -> FileOperation {
    return FileOperation {
        ok: raw >= 0,
        count: if raw >= 0 {
            raw
        } else {
            0
        },
        error: if raw < 0 {
            (-raw)as i32
        } else {
            0
        },
    };
}
