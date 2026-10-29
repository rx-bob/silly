// Real named-lane execution protects whole native DB and ZIP sequences, including shutdown.
namespace native_state_test;

import native_bindings from "../../examples/promptnook_contract";
import native_state from "../../examples/promptnook_contract";
import silly from "../../";

import std;

import.body_socket_fixture;
import.connection_socket_fixture;
import.native_control;
import.native_socket_fixture;

struct WrongThreadDone {
    rejected: bool
}

thread_fn wrong_thread() {
    assert(qput(WrongThreadDone {
            rejected: promptnook_native_example::promptnook_contract_prepare(99) == -1
        }));
}

fn detector_checks() {
    assert(native_control::native_test_reset(0) == 0);
    assert(promptnook_native_example::promptnook_contract_open() == 0);
    assert(promptnook_native_example::promptnook_contract_prepare(11) == 0);
    // Starting ZIP while a DB sequence is active must fail even on the correct thread.
    assert(promptnook_native_example::promptnook_contract_zip_reset(33) == -1);
    assert(promptnook_native_example::promptnook_contract_bind(11) == 0);
    assert(promptnook_native_example::promptnook_contract_query() == 0);
    assert(promptnook_native_example::promptnook_contract_read() == 117);
    qlimit<WrongThreadDone>(1);
    let worker = thread_spawn(wrong_thread);
    let done, present = qget<WrongThreadDone>(10000);
    assert(present);
    assert(done.rejected);
    assert(thread_wait(worker));
    assert(promptnook_native_example::promptnook_contract_close() == 0);
    assert(native_control::native_test_metric(2) == 2);
}

fn serialized_sequences(kind: i32, lanes: i64) {
    assert(native_control::native_test_reset(0) == 0);
    var running = native_socket::start(10000, lanes);
    assert(native_control::native_test_metric(0) == 1);
    var first = body_socket::connect(running.port);
    var second = body_socket::connect(running.port);
    var independent = body_socket::connect(running.port);
    native_socket::health(first);
    native_socket::health(second);
    native_socket::health(independent);
    assert(native_control::native_test_arm(kind) == 0);
    native_socket::request(first, if kind == 1 {
            "/api/db/first"
        } else {
            "/api/export/first"
        });
    assert(native_control::native_test_wait(10000) == 0);
    native_socket::request(second, if kind == 1 {
            "/api/db/second"
        } else {
            "/api/export/second"
        });
    // One native sequence is paused, a second request overlaps, and the same IO pool remains live.
    native_socket::health(independent);
    assert(native_control::native_test_metric(if kind == 1 {
            3
        } else {
            5
        }) == 1);
    assert(native_control::native_test_metric(if kind == 1 {
            4
        } else {
            6
        }) == 0);
    assert(native_control::native_test_metric(2) == 0);
    assert(native_control::native_test_release() == 0);
    connection_socket::exact(connection_socket::receive(first), 1, 200, if kind == 1 {
            "db:117"
        } else {
            "zip:3303"
        });
    connection_socket::exact(connection_socket::receive(second), 1, 200, if kind == 1 {
            "db:227"
        } else {
            "zip:4403"
        });
    native_socket::finish(running, 2);
    assert(native_control::native_test_metric(0) == 1);
    assert(native_control::native_test_metric(1) == 1);
    assert(native_control::native_test_metric(2) == 0);
    assert(native_control::native_test_metric(if kind == 1 {
            3
        } else {
            5
        }) == 2);
    assert(native_control::native_test_metric(if kind == 1 {
            4
        } else {
            6
        }) == 2);
    silly_transport::close(first);
    silly_transport::close(second);
    silly_transport::close(independent);
}

fn shutdown_active_and_queued(kind: i32) {
    assert(native_control::native_test_reset(0) == 0);
    var running = native_socket::start(300);
    var active = body_socket::connect(running.port);
    var queued = body_socket::connect(running.port);
    native_socket::health(active);
    native_socket::health(queued);
    assert(native_control::native_test_arm(kind) == 0);
    native_socket::request(active, if kind == 1 {
            "/api/db/first"
        } else {
            "/api/export/first"
        });
    assert(native_control::native_test_wait(10000) == 0);
    native_socket::request(queued, if kind == 1 {
            "/api/db/second"
        } else {
            "/api/export/second"
        });
    // A 504 is deterministic admission evidence: queued work owns a credit but never entered native code.
    connection_socket::exact(connection_socket::receive(queued), 1, 504, "");
    connection_socket::exact(connection_socket::receive(active), 1, 504, "");
    assert(silly_transport::notify(running.wake).status == silly_transport::IoStatus.Ready);
    native_socket::io_stopped();
    let done, completed = qpoll<native_socket::RuntimeDone>();
    assert(!completed);
    assert(native_control::native_test_metric(1) == 0);
    assert(native_control::native_test_metric(if kind == 1 {
            3
        } else {
            5
        }) == 1);
    assert(native_control::native_test_release() == 0);
    native_socket::joined(running, 1, true);
    assert(native_control::native_test_metric(0) == 1);
    assert(native_control::native_test_metric(1) == 1);
    assert(native_control::native_test_metric(2) == 0);
    assert(native_control::native_test_metric(if kind == 1 {
            4
        } else {
            6
        }) == 1);
    silly_transport::close(active);
    silly_transport::close(queued);
}

fn failed_start() {
    assert(native_control::native_test_reset(1) == 0);
    var running = native_socket::start();
    native_socket::joined(running, 0, false, false);
    assert(native_control::native_test_metric(0) == 0);
    assert(native_control::native_test_metric(1) == 0);
    assert(native_control::native_test_metric(2) == 0);
    assert(native_control::native_test_metric(7) == 1);
}

fn::main() {
    native_state_test::detector_checks();
    native_state_test::serialized_sequences(1, 1);
    native_state_test::serialized_sequences(2, 2);
    native_state_test::shutdown_active_and_queued(1);
    native_state_test::shutdown_active_and_queued(2);
    native_state_test::failed_start();
    print("named native ownership, DB/ZIP serialization and cooperative cleanup passed");
}
