// Real local HTTP/TLS requests use the isolated client package without importing core.
namespace client_transport_test;

import client from "../../client";
import silly from "../../";

import std;

import.client_abandon_cases;
import.client_deadline_cases;
import.client_transport_cases;

fn::main() {
    client_abandon::lifecycle();
    client_cases::reuse_and_tls();
    client_cases::pause_resume();
    client_cases::saturation_cancel();
    client_cases::fifo_slot_reuse();
    client_cases::failures();
    client_deadlines::phases();
    client_deadlines::paused_deadline();
    client_deadlines::queued();
    client_deadlines::shutdown();
    print("client HTTP/TLS, reuse, bounded pause, deadlines, cancellation and ownership passed");
}
