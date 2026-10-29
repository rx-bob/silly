// Test process coordination only; production request paths never use these filesystem helpers.
#define _POSIX_C_SOURCE 200809L
#include <stdint.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
typedef struct { uint8_t *data; int64_t len; } proxy_bytes;
static atomic_llong inspections[16], lengths[16], cancellations, cancellations_by_tag[16];
int64_t silly_proxy_config(int32_t item, proxy_bytes output) {
    const char *name = item == 0 ? "SILLY_PROXY_UPSTREAM" : item == 1 ? "SILLY_PROXY_REFUSED" : "SILLY_PROXY_STALL";
    const char *value = getenv(name);
    if (!value || output.len < 0 || strlen(value) > (size_t)output.len) return -1;
    memcpy(output.data, value, strlen(value));
    return (int64_t)strlen(value);
}
int32_t silly_proxy_ready(int32_t port) {
    const char *path = getenv("SILLY_PROXY_READY");
    char temporary[4096];
    if (!path || strlen(path) + sizeof ".tmp" > sizeof temporary) return -1;
    snprintf(temporary, sizeof temporary, "%s.tmp", path);
    FILE *file = fopen(temporary, "w");
    if (!file) return -1;
    int ok = fprintf(file, "%d", port) > 0;
    if (fclose(file) || !ok) { unlink(temporary); return -1; }
    // Existence now means a complete port is visible, never an empty or partially written file.
    if (rename(temporary, path)) { unlink(temporary); return -1; }
    return 0;
}
int32_t silly_proxy_stop(void) {
    const char *path = getenv("SILLY_PROXY_STOP");
    return path && access(path, F_OK) == 0;
}
void silly_proxy_inspected(int64_t tag, int64_t size) {
    if (tag >= 0 && tag < 16) { atomic_fetch_add(&inspections[tag], 1); atomic_store(&lengths[tag], size); }
}
void silly_proxy_cancelled(int64_t tag) {
    atomic_fetch_add(&cancellations, 1);
    if (tag >= 0 && tag < 16) atomic_fetch_add(&cancellations_by_tag[tag], 1);
}
int64_t silly_proxy_stat(int32_t item, int64_t tag) {
    if (item == 2) return atomic_load(&cancellations);
    if (tag < 0 || tag >= 16) return -1;
    if (item == 3) return atomic_load(&cancellations_by_tag[tag]);
    return item ? atomic_load(&lengths[tag]) : atomic_load(&inspections[tag]);
}
