// Validated finite memory/work budgets for the initial single-owner HTTP server.
namespace silly;

import.limits;
import.transport;

struct ServerOptions {
    address: const u8[:] = "127.0.0.1",
    port: i32 = 8081,
    limits: Limits = Limits {
    },
    connections_max: i64 = 16,
    response_head_bytes_max: i64 = 64 * 1024,
    buffer_bytes_max: i64 = 256 * 1024 * 1024,
    work_bytes_per_turn: i64 = 64 * 1024,
    accepts_per_turn: i64 = 16,
    idle_timeout_ms: i64 = 30000,
    poll_timeout_ms: i32 = 100,
}

enum ServerError {
    None,
    InvalidOptions,
    Listen,
    Accept,
    Wake,
    Clock,
    Poll,
}

struct ServerResult {
    ok: bool,
    error: ServerError = ServerError.None,
    message: const u8[:] = "",
    system_error: i32 = 0,
}

fn valid_server_options(options: ServerOptions) -> bool {
    if !valid(options.limits) || options.port < 0 || options.port > 65535 {
        return false;
    }
    if options.connections_max <= 0 || options.connections_max > silly_transport::POLL_MAX - 2
        || options.response_head_bytes_max < 128 || options.buffer_bytes_max <= 0 {
        return false;
    }
    if options.work_bytes_per_turn <= 0 || options.accepts_per_turn <= 0
        || options.accepts_per_turn > options.connections_max || options.idle_timeout_ms <= 0
        || options.poll_timeout_ms <= 0 || options.poll_timeout_ms > options.idle_timeout_ms {
        return false;
    }
    let per_slot = options.buffer_bytes_max / options.connections_max;
    if options.limits.head_bytes_max > per_slot {
        return false;
    }
    let remainder = per_slot - options.limits.head_bytes_max;
    if options.response_head_bytes_max > remainder {
        return false;
    }
    return options.limits.output_bytes_max <= remainder - options.response_head_bytes_max;
}
