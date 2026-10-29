// Native mutex linearization identifies one runtime and one current handle revision.
namespace silly;

extern fn silly_control_begin() -> i64;

extern fn silly_control_stage(epoch: i64) -> i32;

extern fn silly_control_admit(epoch: i64) -> i32;

extern fn silly_control_submit_begin(epoch: i64) -> i32;

extern fn silly_control_submit_end(epoch: i64);

extern fn silly_control_submissions(epoch: i64) -> i64;

extern fn silly_control_advance(epoch: i64, stage: i32);

extern fn silly_control_ticket(epoch: i64) -> i64;

extern fn silly_control_claim_ticket(epoch: i64, ticket: i64) -> i32;

extern fn silly_control_claim(epoch: i64) -> i32;

extern fn silly_control_release(epoch: i64) -> i64;

extern fn silly_control_finish(epoch: i64, poison: i32);

extern fn silly_control_poisoned() -> i32;

fn runtime_control_begin() -> i64 {
    return silly_control_begin();
}

fn runtime_control_stage(epoch: i64) -> i32 {
    return silly_control_stage(epoch);
}

fn runtime_control_admit(epoch: i64) -> bool {
    return silly_control_admit(epoch) != 0;
}

fn runtime_control_close(epoch: i64) {
    silly_control_advance(epoch, 1);
}

fn runtime_control_cancel(epoch: i64) {
    silly_control_advance(epoch, 2);
}

fn runtime_control_poison(epoch: i64) {
    silly_control_advance(epoch, 3);
}

fn runtime_control_ticket(epoch: i64) -> i64 {
    return silly_control_ticket(epoch);
}

fn runtime_control_claim_ticket(epoch: i64, ticket: i64) -> bool {
    return silly_control_claim_ticket(epoch, ticket) != 0;
}

fn runtime_control_claim(epoch: i64) -> bool {
    return silly_control_claim(epoch) != 0;
}

fn runtime_control_release(epoch: i64) -> i64 {
    return silly_control_release(epoch);
}

fn runtime_control_finish(epoch: i64, poison: bool) {
    silly_control_finish(epoch, if poison {
            1
        } else {
            0
        });
}

fn runtime_control_poisoned() -> bool {
    return silly_control_poisoned() != 0;
}

fn runtime_control_submit_begin(epoch: i64) -> bool {
    return silly_control_submit_begin(epoch) != 0;
}

fn runtime_control_submit_end(epoch: i64) {
    silly_control_submit_end(epoch);
}

fn runtime_control_submissions(epoch: i64) -> i64 {
    return silly_control_submissions(epoch);
}
