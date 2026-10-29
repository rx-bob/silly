// Integrated disposable API/Portal listeners, native ownership, policy and bounded HTTP contracts.
namespace promptnook_integration_test;

import adapters from "../../../examples/promptnook_contract";
import native_bindings from "../../../examples/promptnook_contract";
import native_state from "../../../examples/promptnook_contract";
import silly from "../../../";

import std;

import.native_control;
import.native_socket_fixture;
import.promptnook_integration_cases;
import.promptnook_integration_runtime;
import.promptnook_integration_types;

fn completions() {
    var handler_count: i64 = 0;
    var transfer_count: i64 = 0;
    var native_count: i64 = 0;
    var cancelled: i64 = 0;
    var ids: i64 = 0;
    for index in 128 {
        let finished, present = qpoll<pn_integration::Finished>();
        if !present {
            break;
        }
        if finished.handler {
            handler_count += 1;
            if finished.lane == 0 {
                native_count += 1;
            }
            assert(finished.data.handler_ran);
        } else {
            transfer_count += 1;
            assert(finished.lane < 0);
            if finished.data.transfer == silly::TransferOutcome.Cancelled {
                cancelled += 1;
            }
        }
        if finished.data.audit.request_id.len > 0 {
            assert(finished.data.audit.request_id == "fixture-0" || finished.data.audit.request_id == "fixture-1");
            ids += 1;
        }
    }
    assert(handler_count == 14);
    assert(native_count == 7);
    assert(transfer_count == 17);
    assert(cancelled == 1);
    assert(ids == 27);
}

fn::main() {
    var running = pn_integration::start();
    pn_integration::policy_and_adapters(running);
    pn_integration::cross_listener_serialization(running);
    pn_integration::large_chunked_and_limits(running);
    pn_integration::disconnect_native(running);
    pn_integration::finish(running);
    promptnook_integration_test::completions();
    assert(native_control::native_test_metric(5) == 1);
    assert(native_control::native_test_metric(6) == 1);
    print("API/Portal native ownership, lifecycle, CORS, adapters and bounded body integration passed");
}
