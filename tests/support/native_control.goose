// Canonical test-only controls for the disposable native-state interleaving detector.
namespace native_control;

extern fn native_test_reset(failing: i32) -> i32;

extern fn native_test_arm(kind: i32) -> i32;

extern fn native_test_wait(timeout_ms: i32) -> i32;

extern fn native_test_release() -> i32;

extern fn native_test_metric(index: i32) -> i64;
