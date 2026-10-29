// Force peer reset to exercise cancellation while output remains pending.
#include <stdint.h>
#include <sys/socket.h>
int32_t silly_lifecycle_reset_close(int32_t fd) {
    struct linger immediate = {1, 0};
    return setsockopt(fd, SOL_SOCKET, SO_LINGER, &immediate, sizeof immediate);
}
