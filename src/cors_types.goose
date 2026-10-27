// CORS startup inputs compile into fixed owned policy and per-request decision records.
namespace silly;

import.response;

struct CorsPolicy {
    origin: const u8[:] = "",
    origins: const u8[:] = "",
    methods: const u8[:] = "GET, HEAD, POST",
    headers: const u8[:] = "",
    expose_headers: const u8[:] = "",
    credentials: bool = false,
    preflight_status: i32 = 204,
    options_without_origin: bool = false,
    max_age_seconds: i64 = 0,
}
struct CorsConfig {
    error: ResponseError = ResponseError.None,
    enabled: bool = false,
    origins: u8[..2048] = [],
    methods: u8[..256] = [],
    headers: u8[..512] = [],
    expose_headers: u8[..512] = [],
    credentials: bool = false,
    preflight_status: i32 = 204,
    options_without_origin: bool = false,
    max_age_seconds: i64 = 0,
}
struct CorsDecision {
    enabled: bool = false,
    allowed: bool = false,
    preflight: bool = false,
    vary_preflight: bool = false,
    early_status: i32 = 0,
    origin: u8[..512] = [],
    methods: u8[..256] = [],
    headers: u8[..512] = [],
    expose_headers: u8[..512] = [],
    credentials: bool = false,
    vary_origin: bool = false,
    max_age_seconds: i64 = 0,
}
