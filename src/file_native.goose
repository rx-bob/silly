// Synchronous native calls copy arguments/results; only native-owned tokens survive calls.
namespace silly;

extern fn silly_files_root_open(path: const u8[:]) -> i64;

extern fn silly_files_root_close(fd: i32) -> i64;

extern fn silly_files_start(workers: i32, capacity: i32, chunk_bytes: i32) -> i64;

extern fn silly_files_open(epoch: i64, root: i32, path: const u8[:]) -> i64;

extern fn silly_files_status(epoch: i64, token: i64) -> i64;

extern fn silly_files_size(epoch: i64, token: i64) -> i64;

extern fn silly_files_read(epoch: i64, token: i64, offset: i64, count: i64) -> i64;

// Writable result slice is intentional; use the existing narrow G015 FFI formatter exception.
extern fn silly_files_take(epoch: i64, token: i64, output: u8[:]) -> i64;

extern fn silly_files_cancel(epoch: i64, token: i64) -> i64;

extern fn silly_files_stop(epoch: i64) -> i64;

extern fn silly_files_finish(epoch: i64) -> i64;

extern fn silly_files_pending(epoch: i64) -> i64;

extern fn silly_files_metadata(epoch: i64, token: i64, output: i64[:]) -> i64;
