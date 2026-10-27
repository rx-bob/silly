namespace proxy_fixture;

extern fn silly_proxy_config(item: i32, output: u8[:]) -> i64;

extern fn silly_proxy_ready(port: i32) -> i32;

extern fn silly_proxy_stop() -> i32;

extern fn silly_proxy_inspected(tag: i64, size: i64);

extern fn silly_proxy_cancelled();

extern fn silly_proxy_stat(item: i32, tag: i64) -> i64;
