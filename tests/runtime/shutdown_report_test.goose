// A clean owner exit reported before Start is a recoverable stop, never an unreported abort.
namespace shutdown_report_test;

import silly from "../../";

import std;

thread_fn early_owner(start: silly::WorkerStart, seed: i64) {
    var wake = silly_transport::Descriptor {
        fd: start.wake
    };
    silly_transport::close(wake);
    silly::publish_worker_report(start.report_wake, silly::WorkerReport {
            owner: start.owner,
            ok: true,
            ..
        });
}

fn run() {
    var listener = silly_transport::listen("127.0.0.1", 0, 4);
    assert(listener.status == silly_transport::IoStatus.Ready);
    var wake = silly_transport::wake_pair();
    assert(wake.status == silly_transport::IoStatus.Ready);
    let result = silly::run_runtime(silly::RuntimeOptions {
        }, listener.descriptor, wake.reader, 0, early_owner);
    listener.descriptor.fd = -1;
    wake.reader.fd = -1;
    assert(!result.ok);
    assert(result.error == silly::ServerError.WorkerExited);
    assert(result.drain == silly::DrainStatus.Complete);
    assert(result.unrecovered_owners == 0);
    assert(!result.pending.active);
    assert(!silly::runtime_control_poisoned());
    silly_transport::close(wake.writer);
}

fn::main() {
    for attempt in 32 {
        shutdown_report_test::run();
    }
    print("reported early owner exits remain recoverable across repeated monitor races");
}
