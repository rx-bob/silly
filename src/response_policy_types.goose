// Scoped declarations retain offsets and fixed owned policy; request decisions borrow nothing.
namespace silly;

import.cors_types;
import.response;

struct ResponsePolicyEntry {
    prefix_start: i64,
    prefix_bytes: i64,
    error_policy: i64 = 0,
    cors: CorsConfig = CorsConfig {
    },
}
const EMPTY_RESPONSE_POLICIES: ResponsePolicyEntry[0] = [];

struct ResponsePolicyState {
    error: ResponseError = ResponseError.None,
    error_policy: i64 = 0,
    cors: CorsDecision = CorsDecision {
    },
    allow: u8[..512] = [],
    method_not_allowed: bool = false,
}
