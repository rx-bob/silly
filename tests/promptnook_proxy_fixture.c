// Local test coordination; no production configuration is read.
#define _POSIX_C_SOURCE 200809L
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
typedef struct { uint8_t *data; int64_t len; } fixture_bytes;
int64_t pn_contract_config(int32_t item, fixture_bytes output) {
    const char *names[] = {"PN_TEST_HTTP", "PN_TEST_HTTPS", "PN_TEST_REFUSED", "PN_TEST_CA", "PN_TEST_MISMATCH"};
    if (item < 0 || item >= 5) return -1;
    const char *value = getenv(names[item]);
    if (!value || output.len < 0 || strlen(value) > (size_t)output.len) return -1;
    memcpy(output.data, value, strlen(value));
    return (int64_t)strlen(value);
}
int32_t pn_contract_ready(int32_t port) {
    const char *path = getenv("PN_TEST_READY");
    FILE *file = path ? fopen(path, "w") : NULL;
    if (!file) return -1;
    int ok = fprintf(file, "%d", port) > 0;
    return fclose(file) || !ok ? -1 : 0;
}
int32_t pn_contract_stop(void) {
    const char *path = getenv("PN_TEST_STOP");
    return path && access(path, F_OK) == 0;
}
