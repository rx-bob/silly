namespace client_fixture;

extern fn silly_client_fixture_config(item: i32, output: u8[:]) -> i64;

extern fn silly_client_fixture_now() -> i64;

extern fn silly_client_fixture_wait(fd: i32, timeout: i32) -> i32;
