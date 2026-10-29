// Executor payload reservations and route-lane availability are checked before admission.
namespace executor_runtime_options_test;

import silly from "../../";

import std;

fn budgets() {
    var options = silly::RuntimeOptions {
    };
    assert(silly::runtime_executor_payload_bytes(options) == 0);
    options.executor.lanes = 1;
    assert(silly::valid_runtime_options(options));
    let payload = silly::runtime_executor_payload_bytes(options);
    assert(payload == (1 * (8 + 6) + 1 * (8 + 3)) * 81920);
    options.buffer_bytes_max = silly::worker_buffer_bytes(options.worker) + payload;
    assert(silly::valid_runtime_options(options));
    options.buffer_bytes_max -= 1;
    assert(!silly::valid_runtime_options(options));
    options.buffer_bytes_max += 1;
    options.executor.queue_max += 1;
    assert(!silly::valid_runtime_options(options));
    options.buffer_bytes_max = 512 * 1024 * 1024;
    options.executor.lanes = 2;
    assert(!silly::valid_runtime_options(options));
    options.executor.independent_lanes = true;
    assert(silly::valid_runtime_options(options));
    options.executor.lanes = 5;
    assert(!silly::valid_runtime_options(options));
    options.executor.lanes = 1;
    options.executor.outstanding_per_owner = 0;
    assert(!silly::valid_runtime_options(options));
    options.executor.outstanding_per_owner = 9223372036854775807;
    assert(!silly::valid_runtime_options(options));
}

fn lane_routes() {
    var entries: silly::RouteEntry<i32>[>..] = [];
    var segments: silly::RouteSegment[>..] = [];
    var bytes: u8[>..] = [];
    var router = silly::Router<i32> {
        entries: entries,
        segments: segments,
        bytes: bytes,
        ..
    };
    router.get("/inline", 1);
    router.get("/lane", 2, silly::RouteOptions {
            execution: silly::ExecutionClass.Lane {
                index: 1
            },
            ..
        });
    let plan = silly::prepare(router);
    assert(plan.issue.error == silly::RouteError.None);
    assert(silly::runtime_execution_issue(plan, 2).error == silly::RouteError.None);
    let issue = silly::runtime_execution_issue(plan, 1);
    assert(issue.error == silly::RouteError.UnsupportedOptions);
    assert(issue.route_id == 1);
    assert(silly::runtime_execution_issue(plan, 0).error == silly::RouteError.UnsupportedOptions);
}

fn::main() {
    executor_runtime_options_test::budgets();
    executor_runtime_options_test::lane_routes();
    print("executor runtime options passed");
}
