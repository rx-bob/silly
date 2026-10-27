#include <stdint.h>
#include <sys/socket.h>
int32_t silly_stream_shutdown_write(int32_t fd) { return shutdown(fd, SHUT_WR); }

int32_t silly_stream_reset(int32_t fd) {
    struct linger immediate = {1, 0};
    return setsockopt(fd, SOL_SOCKET, SO_LINGER, &immediate, sizeof immediate);
}
