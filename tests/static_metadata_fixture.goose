// Writable fixture output is checked with the narrow FFI formatter configuration.
namespace static_fixture;

extern fn silly_metadata_fixture_create(output: u8[:]) -> i64;

extern fn silly_metadata_fixture_replace() -> i32;

extern fn silly_metadata_fixture_remove() -> i32;
