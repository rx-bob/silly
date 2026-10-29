// Test-only half-close keeps the client read side open for classified truncation replies.
#include <stdint.h>
#include <sys/socket.h>

int32_t silly_test_finish_input(int32_t fd) {
    return shutdown(fd, SHUT_WR);
}
