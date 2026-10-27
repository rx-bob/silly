// Validated finite memory/work budgets for the initial single-owner HTTP server.
namespace silly;

import.body_types;
import.limits;
import.route_types;
import.transport;

struct ServerOptions {
    address: const u8[:] = "127.0.0.1",
    port: i32 = 8081,
    limits: Limits = Limits {
    },
    connections_max: i64 = 16,
    response_head_bytes_max: i64 = 64 * 1024,
    buffer_bytes_max: i64 = 512 * 1024 * 1024,
    work_bytes_per_turn: i64 = 64 * 1024,
    accepts_per_turn: i64 = 16,
    idle_timeout_ms: i64 = 30000,
    poll_timeout_ms: i32 = 100,
    body_limits: BodyLimits = BodyLimits {
    },
    body_read_bytes_max: i64 = 16384,
    route_limits: RouteLimits = RouteLimits {
    },
}

enum ServerError {
    None,
    InvalidOptions,
    Listen,
    Accept,
    Wake,
    Clock,
    Poll,
    Routes,
}

struct ServerResult {
    ok: bool,
    error: ServerError = ServerError.None,
    message: const u8[:] = "",
    system_error: i32 = 0,
    route_issue: RouteIssue = RouteIssue {
    },
}

fn valid_server_options(options: ServerOptions) -> bool {
    if !valid(options.limits) || !valid_body_limits(options.body_limits)
        || options.body_read_bytes_max <= 0 || options.port < 0 || options.port > 65535 {
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
    var remaining = remainder - options.response_head_bytes_max;
    if options.limits.output_bytes_max > remaining {
        return false;
    }
    remaining -= options.limits.output_bytes_max;
    if options.limits.body_bytes_max > remaining {
        return false;
    }
    remaining -= options.limits.body_bytes_max;
    return server_read_bytes(options) <= remaining;
}

fn server_read_bytes(options: ServerOptions) -> i64 {
    return if options.body_read_bytes_max < options.work_bytes_per_turn {
        options.body_read_bytes_max
    } else {
        options.work_bytes_per_turn
    };
}
