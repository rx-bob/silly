// Fixture output is writable only during the synchronous native setup call.
namespace file_fixture;

extern fn silly_files_fixture_create(output: u8[:]) -> i64;

extern fn silly_files_fixture_remove() -> i32;

extern fn silly_files_fixture_truncate() -> i32;
