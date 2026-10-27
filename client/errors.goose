// Boundary error numbers are stable and distinct from retained libcurl diagnostic codes.
namespace silly_client;

import.types;

fn client_error(code: i64) -> ClientError {
    return match code {
        0 => ClientError.None,
        1 => ClientError.Invalid,
        2 => ClientError.Capacity,
        3 => ClientError.Unsupported,
        4 => ClientError.Dns,
        5 => ClientError.Connect,
        6 => ClientError.Tls,
        7 => ClientError.Timeout,
        8 => ClientError.Cancelled,
        9 => ClientError.Reset,
        10 => ClientError.Limit,
        11 => ClientError.Protocol,
        13 => ClientError.Stale,
        14 => ClientError.Busy,
        15 => ClientError.Decoding,
        _ => ClientError.Internal,
    };
}
