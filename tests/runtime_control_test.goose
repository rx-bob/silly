// Epochs and revision tickets reject stale or concurrently copied cleanup handles.
namespace runtime_control_test;

import silly from "..";

import std;

struct OtherClaim {
    claimed: bool,
    release: i64
}

thread_fn other(epoch: i64) {
    let claimed = silly::runtime_control_claim_ticket(epoch, 0);
    let release = silly::runtime_control_release(epoch);
    silly::runtime_control_finish(epoch, false);
    assert(qput(OtherClaim {
            claimed: claimed,
            release: release
        }));
}

fn control() {
    assert(silly::runtime_control_stage(0) == 0);
    assert(silly::runtime_control_admit(0));
    assert(silly::runtime_control_submit_begin(0));
    silly::runtime_control_submit_end(0);
    assert(silly::runtime_control_submissions(0) == 0);
    assert(!silly::runtime_control_claim(0));
    assert(!silly::runtime_control_poisoned());
    let first = silly::runtime_control_begin();
    assert(first > 0);
    assert(silly::runtime_control_begin() == 0);
    assert(silly::runtime_control_stage(first) == 0);
    assert(silly::runtime_control_admit(first));
    assert(silly::runtime_control_ticket(first) == 0);
    assert(silly::runtime_control_claim_ticket(first, 0));
    assert(!silly::runtime_control_claim(first));
    qlimit<OtherClaim>(1);
    let worker = thread_spawn(other, first);
    let report, present = qget<OtherClaim>(10000);
    assert(present);
    assert(!report.claimed);
    assert(report.release == -1);
    assert(thread_wait(worker));
    assert(silly::runtime_control_stage(first) == 0);
    assert(silly::runtime_control_submit_begin(first));
    assert(silly::runtime_control_submissions(first) == 1);
    silly::runtime_control_close(first);
    assert(silly::runtime_control_stage(first) == 1);
    assert(!silly::runtime_control_submit_begin(first));
    silly::runtime_control_finish(first, false);
    assert(silly::runtime_control_stage(first) == 1);
    assert(silly::runtime_control_submissions(first) == 1);
    silly::runtime_control_submit_end(first);
    assert(silly::runtime_control_submissions(first) == 0);
    assert(!silly::runtime_control_admit(first));
    silly::runtime_control_cancel(first);
    silly::runtime_control_close(first);
    assert(silly::runtime_control_stage(first) == 2);
    let ticket = silly::runtime_control_release(first);
    assert(ticket == 1);
    assert(!silly::runtime_control_claim_ticket(first, 0));
    silly::runtime_control_finish(first, false);
    assert(silly::runtime_control_stage(first) == 2);
    assert(silly::runtime_control_claim_ticket(first, ticket));
    silly::runtime_control_finish(first, false);
    assert(silly::runtime_control_stage(first) == -1);
    assert(!silly::runtime_control_admit(first));
    assert(!silly::runtime_control_claim_ticket(first, ticket));
    stale_and_poison(first);
}

fn stale_and_poison(old: i64) {
    let current = silly::runtime_control_begin();
    assert(current > old);
    silly::runtime_control_poison(old);
    silly::runtime_control_cancel(old);
    silly::runtime_control_finish(old, true);
    silly::runtime_control_submit_end(old);
    assert(silly::runtime_control_submissions(old) == -1);
    assert(silly::runtime_control_submissions(current) == 0);
    assert(silly::runtime_control_stage(current) == 0);
    assert(!silly::runtime_control_poisoned());
    assert(silly::runtime_control_claim_ticket(current, 0));
    silly::runtime_control_poison(current);
    assert(silly::runtime_control_stage(current) == 3);
    assert(silly::runtime_control_poisoned());
    silly::runtime_control_close(current);
    assert(silly::runtime_control_stage(current) == 3);
    silly::runtime_control_finish(current, false);
    assert(silly::runtime_control_stage(current) == 3);
    assert(silly::runtime_control_ticket(current) == 1);
    assert(!silly::runtime_control_claim_ticket(current, 0));
    assert(silly::runtime_control_begin() == 0);
    assert(silly::runtime_control_poisoned());
}

fn::main() {
    runtime_control_test::control();
    print("runtime epochs, exclusive claims, stale tickets and poison passed");
}
