// Static lookups share the bounded file executor and retain native-owned descriptors.
namespace silly;

extern fn silly_files_static_open(epoch: i64, root: i32, path: const u8[:], gzip: i32, freshness: i64) -> i64;

extern fn silly_files_static_info(epoch: i64, token: i64) -> i64;

extern fn silly_files_list(epoch: i64, token: i64, entries: i64, bytes: i64) -> i64;

extern fn silly_files_listing(epoch: i64, token: i64, output: u8[:]) -> i64;

extern fn silly_files_retryable(error: i32) -> i32;
