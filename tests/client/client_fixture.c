// Test-only synchronous configuration and readiness helpers; no retained Goose pointers.
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <poll.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
typedef struct { uint8_t *data; int64_t len; } client_fixture_bytes;
int64_t silly_client_fixture_config(int32_t item, client_fixture_bytes output) {
    const char *name = item == 0 ? "SILLY_CLIENT_HTTP" : item == 1 ? "SILLY_CLIENT_HTTPS"
        : item == 2 ? "SILLY_CLIENT_CA" : item == 3 ? "SILLY_CLIENT_REFUSED" : "SILLY_CLIENT_STALL";
    const char *value = getenv(name);
    if (!value || !output.data || output.len < 0 || strlen(value) > (size_t)output.len) return -1;
    size_t length = strlen(value);
    memcpy(output.data, value, length);
    return (int64_t)length;
}
int64_t silly_client_fixture_now(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now)) return -1;
    return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}
int32_t silly_client_fixture_wait(int32_t fd, int32_t timeout) {
    struct pollfd item = {fd, POLLIN, 0};
    int result = poll(&item, 1, timeout);
    return result < 0 && errno == EINTR ? 0 : result;
}
