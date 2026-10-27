// Bounded filesystem executor. Native workers alone open/read/close transfer descriptors.
#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#endif
#ifndef _DARWIN_C_SOURCE
#define _DARWIN_C_SOURCE 1
#endif
#include <errno.h>
#include <dirent.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <stdint.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include <sys/random.h>

typedef struct { uint8_t *data; int64_t len; } files_bytes;
enum { FILES_SLOTS = 64, FILES_WORKERS = 4, FILES_PATH = 4096, FILES_CHUNK = 4096 };
enum { F_FREE, F_OPEN_QUEUE, F_OPEN_BUSY, F_IDLE, F_READ_QUEUE, F_READ_BUSY,
       F_READY, F_EOF, F_ERROR, F_CLOSE_QUEUE, F_CLOSE_BUSY, F_LIST_QUEUE, F_LIST_BUSY };
struct files_slot {
    int state, cancelled, fd, root_fd, error;
    int64_t token, size, offset, requested, count;
    int64_t modified_seconds, modified_nanoseconds, observed_seconds, device, inode;
    int static_mode, want_gzip, compressed, directory, listing_ready;
    int64_t freshness_ms, entries_max, listing_max, listing_count;
    uint8_t listing[32768];
    char path[FILES_PATH + 1];
    uint8_t bytes[FILES_CHUNK];
};
static pthread_mutex_t files_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t files_wake = PTHREAD_COND_INITIALIZER;
static struct files_slot files_slots[FILES_SLOTS];
static pthread_t files_threads[FILES_WORKERS];
static int files_capacity, files_workers, files_chunk, files_stopping, files_exited, files_joining;
static int files_cursor;
static int64_t files_epoch, files_next_epoch, files_next_token;

#ifdef SILLY_FILES_TEST
extern void silly_files_test_before_read(int fd);
extern void silly_files_test_before_close(int fd);
#endif

static void files_close(int fd) {
    if (fd < 0) return;
#ifdef SILLY_FILES_TEST
    silly_files_test_before_close(fd);
#endif
    close(fd); // Never retry: close may already have released the descriptor on EINTR.
}

static int files_hex(unsigned char byte) {
    if (byte >= '0' && byte <= '9') return byte - '0';
    if (byte >= 'a' && byte <= 'f') return byte - 'a' + 10;
    if (byte >= 'A' && byte <= 'F') return byte - 'A' + 10;
    return -1;
}

// Relative URL path, decoded exactly once. Separators must be literal, unambiguous '/'.
static int files_decode(const char *input, char *output) {
    size_t used = 0, component = 0;
    for (size_t at = 0; input[at]; ++at) {
        unsigned char byte = (unsigned char)input[at];
        if (byte == '%') {
            if (!input[at + 1] || !input[at + 2]) return EINVAL;
            int high = files_hex((unsigned char)input[at + 1]);
            int low = files_hex((unsigned char)input[at + 2]);
            if (high < 0 || low < 0) return EINVAL;
            byte = (unsigned char)(high * 16 + low);
            if (byte == '/' || byte == '\\') return EINVAL;
            at += 2;
        }
        if (byte < 32 || byte == 127 || byte == '\\') return EINVAL;
        if (byte == '/') {
            size_t size = used - component;
            if (!size || (size == 1 && output[component] == '.')
                || (size == 2 && output[component] == '.' && output[component + 1] == '.')) return EINVAL;
            component = used + 1;
        }
        output[used++] = (char)byte;
    }
    size_t size = used - component;
    if (!size || (size == 1 && output[component] == '.')
        || (size == 2 && output[component] == '.' && output[component + 1] == '.')) return EINVAL;
    output[used] = 0;
    return 0;
}

static void files_snapshot(struct files_slot *slot, const struct stat *metadata) {
#ifdef __APPLE__
    slot->modified_seconds = metadata->st_mtimespec.tv_sec;
    slot->modified_nanoseconds = metadata->st_mtimespec.tv_nsec;
#else
    slot->modified_seconds = metadata->st_mtim.tv_sec;
    slot->modified_nanoseconds = metadata->st_mtim.tv_nsec;
#endif
    slot->device = (int64_t)metadata->st_dev;
    slot->inode = (int64_t)metadata->st_ino;
    slot->observed_seconds = (int64_t)time(NULL);
    slot->directory = S_ISDIR(metadata->st_mode);
}

// Every descendant is opened without following links. The supplied root is consumed.
static int files_walk(int root, const char *encoded, int64_t *size, int *error, struct files_slot *slot) {
    char path[FILES_PATH + 1], input[FILES_PATH + 1];
    size_t length = strlen(encoded);
    memcpy(input, encoded, length + 1);
    int require_directory = slot->static_mode && length && input[length - 1] == '/';
    if (require_directory) input[--length] = 0;
    *error = length ? files_decode(input, path) : slot->static_mode ? 0 : EINVAL;
    if (*error) { files_close(root); return -1; }
    struct stat metadata;
    if (fstat(root, &metadata) < 0) { *error = errno; files_close(root); return -1; }
    if (!S_ISDIR(metadata.st_mode)) { *error = ENOTDIR; files_close(root); return -1; }
    if (!length) { files_snapshot(slot, &metadata); *size = 0; return root; }
    char *component = path;
    for (;;) {
        char *slash = strchr(component, '/');
        if (slash) *slash = 0;
        int flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK;
        if (slash) flags |= O_DIRECTORY;
        int next = openat(root, component, flags);
        *error = next < 0 ? errno : 0;
        files_close(root);
        if (next < 0) return -1;
        if (fstat(next, &metadata) < 0) { *error = errno; files_close(next); return -1; }
        if ((slash && !S_ISDIR(metadata.st_mode)) || (!slash && !S_ISREG(metadata.st_mode)
            && !(slot->static_mode && S_ISDIR(metadata.st_mode)))) {
            *error = slash ? ENOTDIR : EINVAL; files_close(next); return -1;
        }
        if (!slash) {
            if (require_directory && !S_ISDIR(metadata.st_mode)) {
                *error = ENOTDIR; files_close(next); return -1;
            }
            if (metadata.st_size < 0 || (uintmax_t)metadata.st_size > INT64_MAX) {
                *error = EOVERFLOW; files_close(next); return -1;
            }
            files_snapshot(slot, &metadata);
            *size = slot->directory ? 0 : (int64_t)metadata.st_size;
            return next;
        }
        root = next;
        component = slash + 1;
    }
}

#include "files_static.h"

static struct files_slot *files_find(int64_t epoch, int64_t token) {
    if (!epoch || epoch != files_epoch || token <= 0) return NULL;
    for (int index = 0; index < files_capacity; ++index)
        if (files_slots[index].state != F_FREE && files_slots[index].token == token) return &files_slots[index];
    return NULL;
}

static int files_next_job(void) {
    for (int offset = 0; offset < files_capacity; ++offset) {
        int index = (files_cursor + offset) % files_capacity;
        int state = files_slots[index].state;
        if (state == F_OPEN_QUEUE || state == F_READ_QUEUE || state == F_CLOSE_QUEUE || state == F_LIST_QUEUE) {
            files_cursor = (index + 1) % files_capacity;
            return index;
        }
    }
    return -1;
}

static void files_finish_job(struct files_slot *slot, int job, int opened, int64_t size,
                             int64_t count, int error) {
    pthread_mutex_lock(&files_lock);
    if (job == F_OPEN_QUEUE && opened >= 0) { slot->fd = opened; slot->size = size; }
    if (slot->cancelled || files_stopping || job == F_CLOSE_QUEUE) {
        int fd = slot->fd, root = slot->root_fd;
        slot->fd = slot->root_fd = -1;
        slot->state = F_CLOSE_BUSY;
        pthread_mutex_unlock(&files_lock);
        files_close(fd);
        files_close(root);
        pthread_mutex_lock(&files_lock);
        memset(slot, 0, sizeof *slot);
        slot->state = F_FREE;
        pthread_cond_broadcast(&files_wake);
    } else {
        slot->error = error;
        slot->count = count;
        slot->state = error ? F_ERROR : job == F_OPEN_QUEUE || job == F_LIST_QUEUE ? F_IDLE : count ? F_READY : F_EOF;
    }
    pthread_mutex_unlock(&files_lock);
}

static void *files_worker(void *unused) {
    (void)unused;
    for (;;) {
        pthread_mutex_lock(&files_lock);
        int index;
        while ((index = files_next_job()) < 0 && !files_stopping)
            pthread_cond_wait(&files_wake, &files_lock);
        if (index < 0) {
            ++files_exited;
            pthread_mutex_unlock(&files_lock);
            return NULL;
        }
        struct files_slot *slot = &files_slots[index];
        int job = slot->state;
        slot->state = job == F_OPEN_QUEUE ? F_OPEN_BUSY : job == F_READ_QUEUE ? F_READ_BUSY
            : job == F_LIST_QUEUE ? F_LIST_BUSY : F_CLOSE_BUSY;
        int fd = slot->fd, root = slot->root_fd;
        if (job == F_OPEN_QUEUE) slot->root_fd = -1;
        pthread_mutex_unlock(&files_lock);
        int opened = -1, error = 0;
        int64_t size = 0, count = 0;
        if (job == F_OPEN_QUEUE) opened = files_open_job(root, slot, &size, &error);
        else if (job == F_LIST_QUEUE) {
#ifdef SILLY_FILES_TEST
            silly_files_test_before_read(fd);
#endif
            error = files_list_job(fd, slot);
        }
        else if (job == F_READ_QUEUE) {
#ifdef SILLY_FILES_TEST
            silly_files_test_before_read(fd);
#endif
            ssize_t got = pread(fd, slot->bytes, (size_t)slot->requested, (off_t)slot->offset);
            if (got < 0) error = errno;
            else count = (int64_t)got;
        }
        files_finish_job(slot, job, opened, size, count, error);
    }
}

int64_t silly_files_root_open(files_bytes path) {
    if (path.len <= 0 || path.len > FILES_PATH || !path.data || (path.len && memchr(path.data, 0, (size_t)path.len))) return -EINVAL;
    char name[FILES_PATH + 1];
    memcpy(name, path.data, (size_t)path.len);
    int64_t length = path.len;
    // A trailing slash would make the kernel follow a final symlink before O_NOFOLLOW applies.
    while (length > 1 && name[length - 1] == '/') --length;
    name[length] = 0;
    int fd = open(name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    return fd < 0 ? -(int64_t)errno : fd;
}

int64_t silly_files_root_close(int32_t fd) {
    if (fd < 0) return -EBADF;
    int result = close(fd);
    return result < 0 ? -(int64_t)errno : 0;
}

int64_t silly_files_start(int32_t workers, int32_t capacity, int32_t chunk_bytes) {
    if (workers < 1 || workers > FILES_WORKERS || capacity < 1 || capacity > FILES_SLOTS
        || chunk_bytes < 1 || chunk_bytes > FILES_CHUNK) return -EINVAL;
    pthread_mutex_lock(&files_lock);
    if (files_epoch) { pthread_mutex_unlock(&files_lock); return -EBUSY; }
    if (files_next_epoch == INT64_MAX) { pthread_mutex_unlock(&files_lock); return -EOVERFLOW; }
    files_epoch = ++files_next_epoch;
    files_capacity = capacity; files_workers = workers; files_chunk = chunk_bytes;
    files_stopping = files_exited = files_joining = files_cursor = 0;
    memset(files_slots, 0, sizeof files_slots);
    int error = 0, created = 0;
    for (; created < workers; ++created) {
        error = pthread_create(&files_threads[created], NULL, files_worker, NULL);
        if (error) break;
    }
    int64_t epoch = files_epoch;
    if (error) { files_stopping = 1; pthread_cond_broadcast(&files_wake); }
    pthread_mutex_unlock(&files_lock);
    if (!error) return epoch;
    for (int index = 0; index < created; ++index) pthread_join(files_threads[index], NULL);
    pthread_mutex_lock(&files_lock);
    files_epoch = 0;
    pthread_mutex_unlock(&files_lock);
    return -error;
}

static int64_t files_admit(int64_t epoch, int32_t root, files_bytes path, int mode, int gzip, int64_t freshness) {
    if ((!path.data && path.len) || path.len < (mode ? 0 : 1) || path.len > FILES_PATH || (path.len && memchr(path.data, 0, (size_t)path.len))) return -EINVAL;
    pthread_mutex_lock(&files_lock);
    if (epoch <= 0 || epoch != files_epoch || files_stopping) { pthread_mutex_unlock(&files_lock); return -ESTALE; }
    int index = 0;
    while (index < files_capacity && files_slots[index].state != F_FREE) ++index;
    if (index == files_capacity) { pthread_mutex_unlock(&files_lock); return -EAGAIN; }
    if (files_next_token == INT64_MAX) { pthread_mutex_unlock(&files_lock); return -EOVERFLOW; }
    int pinned = fcntl(root, F_DUPFD_CLOEXEC, 0);
    if (pinned < 0) { int error = errno; pthread_mutex_unlock(&files_lock); return -error; }
    struct files_slot *slot = &files_slots[index];
    memset(slot, 0, sizeof *slot);
    slot->fd = -1; slot->root_fd = pinned; slot->token = ++files_next_token;
    slot->state = F_OPEN_QUEUE;
    slot->static_mode = mode; slot->want_gzip = gzip; slot->freshness_ms = freshness;
    if (path.len) memcpy(slot->path, path.data, (size_t)path.len);
    slot->path[path.len] = 0;
    int64_t token = slot->token;
    pthread_cond_signal(&files_wake);
    pthread_mutex_unlock(&files_lock);
    return token;
}

int64_t silly_files_open(int64_t epoch, int32_t root, files_bytes path) {
    return files_admit(epoch, root, path, 0, 0, 0);
}
int64_t silly_files_static_open(int64_t epoch, int32_t root, files_bytes path, int32_t gzip, int64_t freshness) {
    if (gzip < 0 || gzip > 1 || freshness < 0 || freshness > 86400000) return -EINVAL;
    return files_admit(epoch, root, path, 1, gzip, freshness);
}

int64_t silly_files_status(int64_t epoch, int64_t token) {
    pthread_mutex_lock(&files_lock);
    struct files_slot *slot = files_find(epoch, token);
    int64_t result = -ESTALE;
    if (slot) {
        if (slot->cancelled) result = -ECANCELED;
        else if (slot->state == F_IDLE) result = 1;
        else if (slot->state == F_READY) result = 2;
        else if (slot->state == F_EOF) result = 3;
        else if (slot->state == F_ERROR) result = -slot->error;
        else result = 0;
    }
    pthread_mutex_unlock(&files_lock);
    return result;
}

int64_t silly_files_size(int64_t epoch, int64_t token) {
    pthread_mutex_lock(&files_lock);
    struct files_slot *slot = files_find(epoch, token);
    int64_t result = !slot ? -ESTALE : slot->cancelled ? -ECANCELED
        : slot->state == F_ERROR ? -slot->error : slot->fd < 0 ? -EAGAIN : slot->size;
    pthread_mutex_unlock(&files_lock);
    return result;
}

int64_t silly_files_read(int64_t epoch, int64_t token, int64_t offset, int64_t count) {
    if (offset < 0 || count <= 0 || offset > INT64_MAX - count || (int64_t)(off_t)offset != offset) return -EINVAL;
    pthread_mutex_lock(&files_lock);
    struct files_slot *slot = files_find(epoch, token);
    int64_t result = !slot ? -ESTALE : slot->cancelled || files_stopping ? -ECANCELED
        : slot->directory ? -EISDIR : count > files_chunk ? -EINVAL : slot->state != F_IDLE && slot->state != F_EOF ? -EBUSY : 0;
    if (!result) {
        slot->offset = offset; slot->requested = count; slot->state = F_READ_QUEUE;
        pthread_cond_signal(&files_wake);
    }
    pthread_mutex_unlock(&files_lock);
    return result;
}

int64_t silly_files_take(int64_t epoch, int64_t token, files_bytes output) {
    if (output.len < 0 || (!output.data && output.len)) return -EINVAL;
    pthread_mutex_lock(&files_lock);
    struct files_slot *slot = files_find(epoch, token);
    int64_t result = !slot ? -ESTALE : slot->cancelled ? -ECANCELED
        : slot->state != F_READY && slot->state != F_EOF ? -EAGAIN : output.len < slot->count ? -ENOBUFS : slot->count;
    if (result >= 0) {
        if (result) memcpy(output.data, slot->bytes, (size_t)result);
        slot->state = F_IDLE; slot->count = 0;
    }
    pthread_mutex_unlock(&files_lock);
    return result;
}

static void files_mark_cancel(struct files_slot *slot) {
    slot->cancelled = 1;
    if (slot->state != F_OPEN_BUSY && slot->state != F_READ_BUSY && slot->state != F_CLOSE_BUSY
        && slot->state != F_LIST_BUSY)
        slot->state = F_CLOSE_QUEUE;
}

int64_t silly_files_cancel(int64_t epoch, int64_t token) {
    pthread_mutex_lock(&files_lock);
    struct files_slot *slot = files_find(epoch, token);
    if (slot) { files_mark_cancel(slot); pthread_cond_signal(&files_wake); }
    pthread_mutex_unlock(&files_lock);
    return slot ? 0 : -ESTALE;
}

int64_t silly_files_stop(int64_t epoch) {
    pthread_mutex_lock(&files_lock);
    if (epoch <= 0 || epoch != files_epoch) { pthread_mutex_unlock(&files_lock); return -ESTALE; }
    files_stopping = 1;
    for (int index = 0; index < files_capacity; ++index)
        if (files_slots[index].state != F_FREE) files_mark_cancel(&files_slots[index]);
    pthread_cond_broadcast(&files_wake);
    pthread_mutex_unlock(&files_lock);
    return 0;
}

int64_t silly_files_pending(int64_t epoch) {
    pthread_mutex_lock(&files_lock);
    int64_t result = 0;
    if (epoch <= 0 || epoch != files_epoch) result = -ESTALE;
    else for (int index = 0; index < files_capacity; ++index) result += files_slots[index].state != F_FREE;
    pthread_mutex_unlock(&files_lock);
    return result;
}

// No active filesystem work is joined. A stopped pool retains its identity until every worker exits.
int64_t silly_files_finish(int64_t epoch) {
    pthread_mutex_lock(&files_lock);
    int64_t result = epoch <= 0 || epoch != files_epoch ? -ESTALE : files_joining ? -EBUSY
        : !files_stopping || files_exited != files_workers ? 0 : 1;
    if (result == 1) files_joining = 1;
    pthread_mutex_unlock(&files_lock);
    if (result != 1) return result;
    for (int index = 0; index < files_workers; ++index) pthread_join(files_threads[index], NULL);
    pthread_mutex_lock(&files_lock);
    files_epoch = 0;
    pthread_mutex_unlock(&files_lock);
    return 1;
}

typedef struct { int64_t *data; int64_t len; } files_ints;
int64_t silly_files_metadata(int64_t epoch, int64_t token, files_ints output) {
    if (!output.data || output.len < 6) return -EINVAL;
    pthread_mutex_lock(&files_lock);
    struct files_slot *slot = files_find(epoch, token);
    int error = !slot ? ESTALE : slot->cancelled ? ECANCELED
        : slot->state == F_ERROR ? slot->error : slot->fd < 0 ? EAGAIN : 0;
    if (!error) {
        output.data[0] = slot->size;
        output.data[1] = slot->modified_seconds;
        output.data[2] = slot->modified_nanoseconds;
        output.data[3] = slot->device;
        output.data[4] = slot->inode;
        output.data[5] = slot->observed_seconds;
    }
    pthread_mutex_unlock(&files_lock);
    return -error;
}

// Bounded OS entropy for multipart boundaries; no process-global pseudo-random state.
int64_t silly_files_random(files_bytes output) {
    if (!output.data || output.len != 16) return -EINVAL;
#ifdef __linux__
    size_t filled = 0;
    while (filled < 16) {
        ssize_t count = getrandom(output.data + filled, 16 - filled, GRND_NONBLOCK);
        if (count < 0) { if (errno == EINTR) continue; return -errno; }
        if (!count) return -EIO;
        filled += (size_t)count;
    }
#else
    if (getentropy(output.data, 16) != 0) return -errno;
#endif
    return 0;
}

// Published flags are read only after the open job releases its slot under files_lock.
int64_t silly_files_static_info(int64_t epoch, int64_t token) {
    pthread_mutex_lock(&files_lock);
    struct files_slot *slot = files_find(epoch, token);
    int64_t result = !slot ? -ESTALE : slot->cancelled ? -ECANCELED
        : slot->state == F_ERROR ? -slot->error : slot->fd < 0 ? -EAGAIN
        : slot->directory ? 2 : slot->compressed ? 3 : 1;
    pthread_mutex_unlock(&files_lock);
    return result;
}
int64_t silly_files_list(int64_t epoch, int64_t token, int64_t entries, int64_t bytes) {
    if (entries < 1 || entries > 128 || bytes < 1 || bytes > 32768) return -EINVAL;
    pthread_mutex_lock(&files_lock);
    struct files_slot *slot = files_find(epoch, token);
    int error = !slot ? ESTALE : slot->cancelled || files_stopping ? ECANCELED
        : slot->state != F_IDLE ? EBUSY : !slot->directory ? ENOTDIR : slot->listing_ready ? EALREADY : 0;
    if (!error) {
        slot->entries_max = entries; slot->listing_max = bytes;
        slot->state = F_LIST_QUEUE; pthread_cond_signal(&files_wake);
    }
    pthread_mutex_unlock(&files_lock);
    return -error;
}
int64_t silly_files_listing(int64_t epoch, int64_t token, files_bytes output) {
    if (output.len < 0 || (!output.data && output.len)) return -EINVAL;
    pthread_mutex_lock(&files_lock);
    struct files_slot *slot = files_find(epoch, token);
    int64_t result = !slot ? -ESTALE : slot->cancelled ? -ECANCELED
        : slot->state == F_ERROR ? -slot->error : slot->state == F_LIST_BUSY || !slot->listing_ready ? -EAGAIN
        : slot->listing_count > output.len ? -ENOBUFS : slot->listing_count;
    if (result > 0) memcpy(output.data, slot->listing, (size_t)result);
    pthread_mutex_unlock(&files_lock);
    return result;
}

int32_t silly_files_retryable(int32_t error) {
    return error == EAGAIN || error == EWOULDBLOCK;
}
