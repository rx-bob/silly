// Canonical test-only socket reset control; never part of the public library package.
namespace lifecycle_native;

extern fn silly_lifecycle_reset_close(fd: i32) -> i32;
