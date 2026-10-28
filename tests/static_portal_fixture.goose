// Native setup creates and removes disposable rooted Portal files.
namespace portal_fixture;

extern fn silly_portal_fixture_create(output: u8[:]) -> i64;

extern fn silly_portal_fixture_remove() -> i32;
