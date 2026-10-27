// Inert caller-owned configuration replaces environment-variable and business-store access.
namespace promptnook_portal;

import client from "../../client";
import proxy from "../../client";
import silly from "../..";

struct Environment {
    name: const u8[:],
    base_url: const u8[:],
    token_configured: bool = false,
    token: const u8[:] = "",
}
const EMPTY_ENVIRONMENTS: Environment[0] = [];
struct Config {
    environments: const Environment[:] = EMPTY_ENVIRONMENTS,
    fallback_url: const u8[:] = "",
    fallback_token: const u8[:] = "inert-example-token",
}
enum PortalError {
    None,
    InvalidEnvironment,
    InvalidTarget,
    Limit,
}
struct Prepared {
    error: PortalError = PortalError.None,
    environment: u8[..128] = [],
    target: u8[..4096] = [],
    authorization: u8[..1024] = [],
    decoding: silly_client::ContentDecoding = silly_client::ContentDecoding.Automatic,
}

fn query_options(separators: u8[:] = "&") -> silly::QueryOptions {
    return silly::QueryOptions {
        separators: separators,
        invalid_escape: silly::InvalidEscape.Literal,
        input_bytes_max: 4096,
        decoded_bytes_max: 4096,
        pairs_max: 128,
    };
}
