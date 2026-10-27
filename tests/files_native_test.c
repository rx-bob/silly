// Deterministic adversarial tests for descriptor-rooted, bounded filesystem jobs.
#define _POSIX_C_SOURCE 200809L
#define _DARWIN_C_SOURCE
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <stdint.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

typedef struct { uint8_t *data; int64_t len; } files_bytes;
extern int64_t silly_files_root_open(files_bytes);
extern int64_t silly_files_root_close(int32_t);
extern int64_t silly_files_start(int32_t, int32_t, int32_t);
extern int64_t silly_files_open(int64_t, int32_t, files_bytes);
extern int64_t silly_files_status(int64_t, int64_t);
extern int64_t silly_files_size(int64_t, int64_t);
extern int64_t silly_files_read(int64_t, int64_t, int64_t, int64_t);
extern int64_t silly_files_take(int64_t, int64_t, files_bytes);
extern int64_t silly_files_cancel(int64_t, int64_t);
extern int64_t silly_files_stop(int64_t);
extern int64_t silly_files_finish(int64_t);
extern int64_t silly_files_pending(int64_t);
extern int64_t silly_files_random(files_bytes);
extern int64_t silly_files_static_open(int64_t, int32_t, files_bytes, int32_t, int64_t);
extern int64_t silly_files_static_info(int64_t, int64_t);
extern int64_t silly_files_list(int64_t, int64_t, int64_t, int64_t);
extern int64_t silly_files_listing(int64_t, int64_t, files_bytes);

static pthread_mutex_t hook_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t hook_changed = PTHREAD_COND_INITIALIZER;
static int hold_read, read_entered, release_read, watched_fd = -1, watched_closes;
static char base[PATH_MAX], root_path[PATH_MAX], outside_path[PATH_MAX];

static files_bytes bytes(const char *text) {
    return (files_bytes){(uint8_t *)text, (int64_t)strlen(text)};
}
static void pause_poll(void) {
    struct timespec delay = {0, 1000000};
    assert(nanosleep(&delay, NULL) == 0 || errno == EINTR);
}
static int64_t settled(int64_t epoch, int64_t token) {
    for (int turn = 0; turn < 10000; ++turn) {
        int64_t status = silly_files_status(epoch, token);
        if (status != 0) return status;
        pause_poll();
    }
    assert(!"filesystem job failed to settle");
    return 0;
}
static void wait_pending(int64_t epoch, int64_t count) {
    for (int turn = 0; turn < 10000; ++turn) {
        if (silly_files_pending(epoch) == count) return;
        pause_poll();
    }
    assert(!"filesystem ownership did not settle");
}
static void finish_pool(int64_t epoch) {
    assert(silly_files_stop(epoch) == 0);
    for (int turn = 0; turn < 10000; ++turn) {
        int64_t done = silly_files_finish(epoch);
        assert(done >= 0);
        if (done == 1) return;
        pause_poll();
    }
    assert(!"filesystem pool failed to finish");
}

void silly_files_test_before_read(int fd) {
    assert(pthread_mutex_lock(&hook_lock) == 0);
    if (hold_read) {
        watched_fd = fd;
        read_entered = 1;
        assert(pthread_cond_broadcast(&hook_changed) == 0);
        while (!release_read) assert(pthread_cond_wait(&hook_changed, &hook_lock) == 0);
    }
    assert(pthread_mutex_unlock(&hook_lock) == 0);
}
void silly_files_test_before_close(int fd) {
    assert(pthread_mutex_lock(&hook_lock) == 0);
    if (fd == watched_fd) ++watched_closes;
    assert(pthread_mutex_unlock(&hook_lock) == 0);
}
static void await_read(void) {
    struct timespec until;
    assert(clock_gettime(CLOCK_REALTIME, &until) == 0);
    until.tv_sec += 10;
    assert(pthread_mutex_lock(&hook_lock) == 0);
    while (!read_entered) assert(pthread_cond_timedwait(&hook_changed, &hook_lock, &until) == 0);
    assert(pthread_mutex_unlock(&hook_lock) == 0);
}

static void path(char *out, size_t cap, const char *parent, const char *name) {
    int n = snprintf(out, cap, "%s/%s", parent, name);
    assert(n >= 0 && (size_t)n < cap);
}
static void write_file(const char *name, size_t size, unsigned seed) {
    int fd = open(name, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    assert(fd >= 0);
    uint8_t chunk[251];
    size_t position = 0;
    while (position < size) {
        size_t count = size - position;
        if (count > sizeof chunk) count = sizeof chunk;
        for (size_t i = 0; i < count; ++i) chunk[i] = (uint8_t)(position + i + seed);
        assert(write(fd, chunk, count) == (ssize_t)count);
        position += count;
    }
    assert(close(fd) == 0);
}
static int64_t open_file(int64_t epoch, int32_t root, const char *name) {
    int64_t token = silly_files_open(epoch, root, bytes(name));
    assert(token > 0);
    assert(settled(epoch, token) == 1);
    return token;
}
static void rejected(int64_t epoch, int32_t root, files_bytes name) {
    int64_t token = silly_files_open(epoch, root, name);
    if (token > 0) {
        assert(settled(epoch, token) < 0);
        assert(silly_files_cancel(epoch, token) == 0);
        wait_pending(epoch, 0);
    } else assert(token < 0);
}

static void setup(void) {
    strcpy(base, "/tmp/silly-files-native-XXXXXX");
    assert(mkdtemp(base));
    path(root_path, sizeof root_path, base, "root");
    path(outside_path, sizeof outside_path, base, "root-other");
    assert(mkdir(root_path, 0700) == 0);
    assert(mkdir(outside_path, 0700) == 0);
    char name[PATH_MAX], target[PATH_MAX];
    path(name, sizeof name, root_path, "binary");
    write_file(name, 65537, 13);
    path(target, sizeof target, outside_path, "secret");
    write_file(target, 31, 99);
    path(name, sizeof name, root_path, "file-link");
    assert(symlink(target, name) == 0);
    path(name, sizeof name, root_path, "dir-link");
    assert(symlink(outside_path, name) == 0);
    path(name, sizeof name, base, "root-link");
    assert(symlink(root_path, name) == 0);
    assert(silly_files_root_open(bytes(name)) < 0);
    size_t link_length = strlen(name);
    assert(link_length + 4 < sizeof name);
    memcpy(name + link_length, "///", 4);
    assert(silly_files_root_open(bytes(name)) < 0);
    name[link_length + 1] = 0;
    assert(silly_files_root_open(bytes(name)) < 0);
    path(name, sizeof name, root_path, "");
    int64_t trailing_root = silly_files_root_open(bytes(name));
    assert(trailing_root >= 0 && trailing_root <= INT32_MAX);
    assert(silly_files_root_close((int32_t)trailing_root) == 0);
    path(name, sizeof name, root_path, "pipe");
    assert(mkfifo(name, 0600) == 0);
    path(name, sizeof name, root_path, "space + name");
    write_file(name, 3, 7);
}
static void security(int64_t epoch, int32_t root) {
    const char *invalid[] = {"", "/binary", "../root-other/secret", "%2e%2e/root-other/secret",
        "a/../../root-other/secret", "dir-link/secret", "file-link", "a%2fb", "a%2Fb",
        "a%5cb", "a\\b", "%", "%0", "%zz", "binary%00", "pipe", "./binary", "a//b", "missing", "binary/child", "root-other/secret"};
    for (size_t i = 0; i < sizeof invalid / sizeof *invalid; ++i) rejected(epoch, root, bytes(invalid[i]));
    char nul[] = {'b', 'i', 'n', 0, 'x'};
    rejected(epoch, root, (files_bytes){(uint8_t *)nul, sizeof nul});
    int64_t token = open_file(epoch, root, "space%20+%20name");
    assert(silly_files_size(epoch, token) == 3);
    assert(silly_files_cancel(epoch, token) == 0);
    wait_pending(epoch, 0);
}
static void exact_reads(int64_t epoch, int32_t root) {
    int64_t token = open_file(epoch, root, "binary");
    assert(silly_files_size(epoch, token) == 65537);
    assert(silly_files_read(epoch, token, -1, 1) < 0);
    assert(silly_files_read(epoch, token, 0, 258) < 0);
    uint8_t chunk[257];
    int64_t position = 0;
    while (position < 65537) {
        assert(silly_files_read(epoch, token, position, 37) == 0);
        assert(settled(epoch, token) == 2);
        assert(silly_files_take(epoch, token, (files_bytes){chunk, 1}) == -ENOBUFS);
        assert(silly_files_status(epoch, token) == 2);
        int64_t count = silly_files_take(epoch, token, (files_bytes){chunk, sizeof chunk});
        assert(count > 0 && count <= 37);
        for (int64_t i = 0; i < count; ++i) assert(chunk[i] == (uint8_t)(position + i + 13));
        position += count;
    }
    assert(silly_files_read(epoch, token, position, 37) == 0);
    assert(settled(epoch, token) == 3);
    assert(silly_files_take(epoch, token, (files_bytes){chunk, sizeof chunk}) == 0);
    assert(silly_files_cancel(epoch, token) == 0);
    wait_pending(epoch, 0);
}
static void identity(int64_t epoch, int32_t root) {
    int64_t pin = silly_files_root_open(bytes(root_path));
    assert(pin >= 0);
    int64_t token = silly_files_open(epoch, (int32_t)pin, bytes("binary"));
    assert(token > 0);
    assert(silly_files_root_close((int32_t)pin) == 0);
    assert(settled(epoch, token) == 1);
    char original[PATH_MAX], replacement[PATH_MAX];
    path(original, sizeof original, root_path, "original");
    path(replacement, sizeof replacement, root_path, "binary");
    assert(rename(replacement, original) == 0);
    write_file(replacement, 11, 77);
    uint8_t chunk[37];
    assert(silly_files_read(epoch, token, 0, sizeof chunk) == 0);
    assert(settled(epoch, token) == 2);
    assert(silly_files_take(epoch, token, (files_bytes){chunk, sizeof chunk}) == sizeof chunk);
    for (size_t i = 0; i < sizeof chunk; ++i) assert(chunk[i] == (uint8_t)(i + 13));
    assert(silly_files_cancel(epoch, token) == 0);
    wait_pending(epoch, 0);
    token = open_file(epoch, root, "binary");
    assert(silly_files_size(epoch, token) == 11);
    assert(silly_files_cancel(epoch, token) == 0);
    wait_pending(epoch, 0);
}
static void capacity(int64_t epoch, int32_t root) {
    int64_t first = open_file(epoch, root, "binary");
    int64_t second = open_file(epoch, root, "binary");
    assert(silly_files_pending(epoch) == 2);
    assert(silly_files_open(epoch, root, bytes("binary")) < 0);
    assert(silly_files_cancel(epoch, first) == 0);
    wait_pending(epoch, 1);
    int64_t reused = open_file(epoch, root, "binary");
    assert(reused != first);
    assert(silly_files_status(epoch, first) < 0);
    assert(silly_files_read(epoch, first, 0, 1) < 0);
    assert(silly_files_cancel(epoch, first) < 0);
    assert(silly_files_status(epoch, reused) == 1);
    assert(silly_files_cancel(epoch, second) == 0);
    assert(silly_files_cancel(epoch, reused) == 0);
    wait_pending(epoch, 0);
}
static _Atomic int race_stop;
static void *swap_path(void *ignored) {
    (void)ignored;
    char live[PATH_MAX], secret[PATH_MAX], source[PATH_MAX];
    path(live, sizeof live, root_path, "race");
    path(secret, sizeof secret, outside_path, "secret");
    path(source, sizeof source, root_path, "binary");
    while (!atomic_load(&race_stop)) {
        if (unlink(live) < 0) assert(errno == ENOENT);
        assert(symlink(secret, live) == 0);
        assert(unlink(live) == 0);
        assert(link(source, live) == 0);
    }
    return NULL;
}
static void symlink_race(int64_t epoch, int32_t root) {
    pthread_t changer;
    assert(pthread_create(&changer, NULL, swap_path, NULL) == 0);
    for (int attempt = 0; attempt < 100; ++attempt) {
        int64_t token = silly_files_open(epoch, root, bytes("race"));
        if (token < 0) continue;
        int64_t status = settled(epoch, token);
        if (status == 1) {
            assert(silly_files_size(epoch, token) == 11);
            assert(silly_files_read(epoch, token, 0, 1) == 0);
            assert(settled(epoch, token) == 2);
            uint8_t byte = 0;
            assert(silly_files_take(epoch, token, (files_bytes){&byte, 1}) == 1);
            assert(byte == 77);
        } else assert(status < 0);
        assert(silly_files_cancel(epoch, token) == 0);
        wait_pending(epoch, 0);
    }
    atomic_store(&race_stop, 1);
    assert(pthread_join(changer, NULL) == 0);
    char live[PATH_MAX];
    path(live, sizeof live, root_path, "race");
    assert(unlink(live) == 0);
}
static void pending_cancel(int32_t root, int directory) {
    int64_t epoch = silly_files_start(1, 1, 257);
    assert(epoch > 0);
    int64_t token = directory ? silly_files_static_open(epoch, root, bytes(""), 0, 0)
        : open_file(epoch, root, "binary");
    assert(token > 0 && settled(epoch, token) == 1);
    assert(pthread_mutex_lock(&hook_lock) == 0);
    read_entered = release_read = watched_closes = 0;
    hold_read = 1;
    assert(pthread_mutex_unlock(&hook_lock) == 0);
    if (directory) assert(silly_files_list(epoch, token, 128, 32768) == 0);
    else assert(silly_files_read(epoch, token, 0, 11) == 0);
    await_read();
    assert(silly_files_cancel(epoch, token) == 0);
    assert(silly_files_pending(epoch) == 1);
    assert(silly_files_open(epoch, root, bytes("binary")) < 0);
    assert(silly_files_stop(epoch) == 0);
    assert(silly_files_finish(epoch) == 0);
    assert(silly_files_open(epoch, root, bytes("binary")) < 0);
    assert(pthread_mutex_lock(&hook_lock) == 0);
    assert(watched_fd >= 0);
    assert(watched_closes == 0);
    assert(fcntl(watched_fd, F_GETFD) >= 0);
    int probe = open("/dev/null", O_RDONLY);
    assert(probe >= 0 && probe != watched_fd);
    assert(close(probe) == 0);
    release_read = 1;
    assert(pthread_cond_broadcast(&hook_changed) == 0);
    assert(pthread_mutex_unlock(&hook_lock) == 0);
    finish_pool(epoch);
    assert(pthread_mutex_lock(&hook_lock) == 0);
    assert(watched_closes == 1);
    assert(fcntl(watched_fd, F_GETFD) < 0 && errno == EBADF);
    watched_fd = -1;
    hold_read = 0;
    assert(pthread_mutex_unlock(&hook_lock) == 0);
    int64_t fresh = silly_files_start(1, 1, 257);
    assert(fresh > 0 && fresh != epoch);
    assert(silly_files_status(epoch, token) < 0);
    assert(silly_files_read(epoch, token, 0, 1) < 0);
    finish_pool(fresh);
}
static void cleanup(void) {
    const char *inside[] = {"binary", "original", "file-link", "dir-link", "pipe", "space + name"};
    char name[PATH_MAX];
    for (size_t i = 0; i < sizeof inside / sizeof *inside; ++i) {
        path(name, sizeof name, root_path, inside[i]);
        assert(unlink(name) == 0);
    }
    path(name, sizeof name, outside_path, "secret");
    assert(unlink(name) == 0);
    path(name, sizeof name, base, "root-link");
    assert(unlink(name) == 0);
    assert(rmdir(root_path) == 0);
    assert(rmdir(outside_path) == 0);
    assert(rmdir(base) == 0);
}
static void static_directories(int64_t epoch, int32_t root) {
    int64_t token = silly_files_static_open(epoch, root, bytes(""), 1, 10);
    assert(token > 0 && settled(epoch, token) == 1);
    assert(silly_files_static_info(epoch, token) == 2);
    assert(silly_files_read(epoch, token, 0, 1) == -EISDIR);
    assert(silly_files_list(epoch, token, 128, 32768) == 0);
    assert(settled(epoch, token) == 1);
    uint8_t listing[32768];
    int64_t count = silly_files_listing(epoch, token, (files_bytes){listing, sizeof listing});
    assert(count > 0);
    assert(silly_files_listing(epoch, token, (files_bytes){listing, 1}) == -ENOBUFS);
    assert(silly_files_list(epoch, token, 128, 32768) == -EALREADY);
    int64_t at = 0;
    while (at < count) {
        assert(count - at >= 3);
        unsigned kind = listing[at], length = listing[at + 1] + listing[at + 2] * 256;
        at += 3;
        assert(kind == 1 && length > 0 && length <= 255 && length <= count - at);
        assert(!(length == 9 && !memcmp(listing + at, "file-link", 9)));
        assert(!(length == 8 && !memcmp(listing + at, "dir-link", 8)));
        at += length;
    }
    assert(silly_files_cancel(epoch, token) == 0); wait_pending(epoch, 0);
    token = silly_files_static_open(epoch, root, bytes(""), 0, 0);
    assert(token > 0 && settled(epoch, token) == 1);
    assert(silly_files_list(epoch, token, 1, 32768) == 0);
    assert(settled(epoch, token) == -EOVERFLOW);
    assert(silly_files_cancel(epoch, token) == 0); wait_pending(epoch, 0);
    const char *invalid[] = {"../", "%2e%2e/", "dir-link/", "file-link", "pipe", "binary/"};
    for (size_t i = 0; i < sizeof invalid / sizeof *invalid; ++i) {
        token = silly_files_static_open(epoch, root, bytes(invalid[i]), 1, 10);
        assert(token > 0 && settled(epoch, token) < 0);
        assert(silly_files_cancel(epoch, token) == 0); wait_pending(epoch, 0);
    }
}
static void boundary_entropy(void) {
    uint8_t storage[18];
    memset(storage, 0xa5, sizeof storage);
    assert(silly_files_random((files_bytes){storage + 1, 15}) == -EINVAL);
    assert(silly_files_random((files_bytes){storage + 1, 17}) == -EINVAL);
    assert(silly_files_random((files_bytes){NULL, 16}) == -EINVAL);
    assert(silly_files_random((files_bytes){storage + 1, 16}) == 0);
    assert(storage[0] == 0xa5 && storage[17] == 0xa5);
}
int main(void) {
    boundary_entropy();
    setup();
    int64_t root = silly_files_root_open(bytes(root_path));
    assert(root >= 0 && root <= INT32_MAX);
    int64_t epoch = silly_files_start(1, 2, 257);
    assert(epoch > 0);
    security(epoch, (int32_t)root);
    static_directories(epoch, (int32_t)root);
    exact_reads(epoch, (int32_t)root);
    identity(epoch, (int32_t)root);
    capacity(epoch, (int32_t)root);
    symlink_race(epoch, (int32_t)root);
    finish_pool(epoch);
    pending_cancel((int32_t)root, 0);
    pending_cancel((int32_t)root, 1);
    assert(silly_files_root_close((int32_t)root) == 0);
    cleanup();
    puts("rooted file security, bounded reads, identity and pending cancellation passed");
    return 0;
}
