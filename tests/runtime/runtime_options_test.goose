// Reservation accounting includes queued admissions and the supervisor's temporary descriptor.
namespace runtime_options_test;

import silly from "../../";

import std;

fn::main() {
    var options = silly::RuntimeOptions {
    };
    assert(silly::valid_runtime_options(options));
    assert(silly::runtime_connections_reserved(options) == 34);
    options.shutdown_timeout_ms = -1;
    assert(!silly::valid_runtime_options(options));
    options.shutdown_timeout_ms = 0;
    assert(silly::valid_runtime_options(options));
    options.signal_token = -1;
    assert(!silly::valid_runtime_options(options));
    options.signal_token = 0;
    options.worker.limits.body_bytes_max = 1024;
    options.worker.limits.output_bytes_max = 1024;
    options.workers = 2;
    assert(!silly::valid_runtime_options(options));
    options.connections_max = 67;
    assert(silly::valid_runtime_options(options));
    options.connections_max = 66;
    assert(!silly::valid_runtime_options(options));
    options.connections_max = 133;
    options.workers = 4;
    assert(silly::valid_runtime_options(options));
    options.workers = 5;
    assert(!silly::valid_runtime_options(options));
    options.workers = 4;
    options.buffer_bytes_max = silly::worker_buffer_bytes(options.worker) * 4;
    assert(silly::valid_runtime_options(options));
    options.buffer_bytes_max -= 1;
    assert(!silly::valid_runtime_options(options));
    options.buffer_bytes_max = 512 * 1024 * 1024;
    options.accept_queue_max = 9223372036854775807;
    assert(!silly::valid_runtime_options(options));
    options.accept_queue_max = 0;
    assert(!silly::valid_runtime_options(options));
    options.accept_queue_max = 16;
    options.worker.work_bytes_per_turn = 0;
    assert(!silly::valid_runtime_options(options));
    options.worker.work_bytes_per_turn = 1024;
    let copied = silly::worker_options(silly::worker_server_options(options.worker));
    assert(copied.work_bytes_per_turn == 1024);
    assert(copied.connections_max == options.worker.connections_max);
    assert(copied.dispatches_per_turn == options.worker.dispatches_per_turn);
}
