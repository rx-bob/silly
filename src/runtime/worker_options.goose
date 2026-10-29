// Flat copied worker settings and conservative process-wide admission reservations.
namespace silly;

import.executor_types;

let IO_WORKERS_MAX = 4;

struct WorkerOptions {
    limits: Limits = Limits {
    },
    connections_max: i64 = 16,
    response_head_bytes_max: i64 = 64 * 1024,
    buffer_bytes_max: i64 = 512 * 1024 * 1024,
    work_bytes_per_turn: i64 = 64 * 1024,
    accepts_per_turn: i64 = 16,
    dispatches_per_turn: i64 = 16,
    idle_timeout_ms: i64 = 30000,
    head_timeout_ms: i64 = 30000,
    body_timeout_ms: i64 = 30000,
    write_timeout_ms: i64 = 30000,
    poll_timeout_ms: i32 = 100,
    body_limits: BodyLimits = BodyLimits {
    },
    body_read_bytes_max: i64 = 16384,
    route_limits: RouteLimits = RouteLimits {
    },
}

struct RuntimeOptions {
    shutdown_timeout_ms: i64 = 5000,
    signal_token: i64 = 0,
    workers: i64 = 1,
    accept_queue_max: i64 = 16,
    connections_max: i64 = 64,
    buffer_bytes_max: i64 = 512 * 1024 * 1024,
    worker: WorkerOptions = WorkerOptions {
    },
    executor: ExecutorOptions = ExecutorOptions {
    },
}

fn worker_server_options(options: WorkerOptions) -> ServerOptions {
    return ServerOptions {
        limits: options.limits,
        connections_max: options.connections_max,
        response_head_bytes_max: options.response_head_bytes_max,
        buffer_bytes_max: options.buffer_bytes_max,
        work_bytes_per_turn: options.work_bytes_per_turn,
        accepts_per_turn: options.accepts_per_turn,
        dispatches_per_turn: options.dispatches_per_turn,
        idle_timeout_ms: options.idle_timeout_ms,
        head_timeout_ms: options.head_timeout_ms,
        body_timeout_ms: options.body_timeout_ms,
        write_timeout_ms: options.write_timeout_ms,
        poll_timeout_ms: options.poll_timeout_ms,
        body_limits: options.body_limits,
        body_read_bytes_max: options.body_read_bytes_max,
        route_limits: options.route_limits,
        ..
    };
}

fn worker_options(options: ServerOptions) -> WorkerOptions {
    return WorkerOptions {
        limits: options.limits,
        connections_max: options.connections_max,
        response_head_bytes_max: options.response_head_bytes_max,
        buffer_bytes_max: options.buffer_bytes_max,
        work_bytes_per_turn: options.work_bytes_per_turn,
        accepts_per_turn: options.accepts_per_turn,
        dispatches_per_turn: options.dispatches_per_turn,
        idle_timeout_ms: options.idle_timeout_ms,
        head_timeout_ms: options.head_timeout_ms,
        body_timeout_ms: options.body_timeout_ms,
        write_timeout_ms: options.write_timeout_ms,
        poll_timeout_ms: options.poll_timeout_ms,
        body_limits: options.body_limits,
        body_read_bytes_max: options.body_read_bytes_max,
        route_limits: options.route_limits,
    };
}

// Call after validating worker options; each addend fits its configured slab budget.
fn worker_buffer_bytes(options: WorkerOptions) -> i64 {
    let server = worker_server_options(options);
    return options.connections_max * (options.limits.head_bytes_max + options.response_head_bytes_max
        + options.limits.output_bytes_max + options.limits.body_bytes_max + server_read_bytes(server));
}

// Includes a temporary dequeued descriptor per worker and one accepted by the supervisor.
// Call after valid_runtime_options; validation performs division before multiplication.
fn runtime_connections_reserved(options: RuntimeOptions) -> i64 {
    return options.workers * (options.worker.connections_max + options.accept_queue_max + 1) + 1;
}

fn valid_runtime_options(options: RuntimeOptions) -> bool {
    if options.shutdown_timeout_ms < 0 || options.signal_token < 0 || options.workers <= 0
        || options.workers > IO_WORKERS_MAX || options.accept_queue_max <= 0
        || options.connections_max <= 1 || options.buffer_bytes_max <= 0 {
        return false;
    }
    if !valid_server_options(worker_server_options(options.worker)) || !valid_executor_options(options.executor) {
        return false;
    }
    let per_worker = (options.connections_max - 1) / options.workers;
    if options.worker.connections_max >= per_worker - 1
        || options.accept_queue_max > per_worker - options.worker.connections_max - 1 {
        return false;
    }
    let executor_bytes = runtime_executor_payload_bytes(options);
    if executor_bytes >= options.buffer_bytes_max {
        return false;
    }
    return worker_buffer_bytes(options.worker) <= (options.buffer_bytes_max - executor_bytes) / options.workers;
}

// Fixed payload arrays reserve their full capacity, regardless of configured admission byte limits.
// Includes queue records plus explicit in-flight work, response and staging copies; excludes metadata,
// native thread stacks and compiler scratch space, as the ordinary slab budget does.
fn runtime_executor_payload_bytes(options: RuntimeOptions) -> i64 {
    if options.executor.lanes == 0 {
        return 0;
    }
    return (options.executor.lanes * (options.executor.queue_max + 6)
        + options.workers * (options.executor.outstanding_per_owner + 3)) * (16384 + 65536);
}
