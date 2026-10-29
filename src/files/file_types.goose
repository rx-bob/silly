// File handles carry only executor identities; native workers retain all file descriptors.
namespace silly;

struct FileExecutorOptions {
    workers: i32 = 1,
    capacity: i32 = 16,
    chunk_bytes: i32 = 4096,
}
struct FileExecutor {
    epoch: i64 = 0,
    chunk_bytes: i32 = 0,
}
struct FileExecutorResult {
    ok: bool,
    executor: FileExecutor = FileExecutor {
    },
    error: i32 = 0,
}
struct FileRoot {
    fd: i32 = -1,
}
struct FileRootResult {
    ok: bool,
    root: FileRoot = FileRoot {
    },
    error: i32 = 0,
}
struct OwnedFile {
    epoch: i64 = 0,
    token: i64 = 0,
    chunk_bytes: i32 = 0,
}
struct FileOpenResult {
    ok: bool,
    file: OwnedFile = OwnedFile {
    },
    error: i32 = 0,
}
enum FileStatus {
    Pending,
    Open,
    Chunk,
    End,
    Failed,
}
struct FileResult {
    status: FileStatus,
    size: i64 = -1,
    error: i32 = 0,
}
struct FileOperation {
    ok: bool,
    count: i64 = 0,
    error: i32 = 0,
}
struct FileFinishResult {
    complete: bool,
    error: i32 = 0,
}
