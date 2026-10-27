// Internal worker helpers; included after the descriptor walker and slot declarations.
#ifndef SILLY_FILES_STATIC_H
#define SILLY_FILES_STATIC_H

static int files_gzip_fresh(const struct files_slot *original, const struct files_slot *gzip) {
    // Compare bounded second differences first; avoid overflowing epoch-to-nanosecond conversion.
    if (gzip->modified_seconds > original->modified_seconds) return 1;
    uint64_t seconds = (uint64_t)original->modified_seconds - (uint64_t)gzip->modified_seconds;
    if (seconds > 86401) return 0;
    int64_t lag = (int64_t)seconds * 1000000000
        + original->modified_nanoseconds - gzip->modified_nanoseconds;
    return lag <= 0 || (original->freshness_ms > 0 && lag < original->freshness_ms * 1000000);
}

static int files_open_job(int root, struct files_slot *slot, int64_t *size, int *error) {
    if (!slot->static_mode || !slot->want_gzip) return files_walk(root, slot->path, size, error, slot);
    int copy = fcntl(root, F_DUPFD_CLOEXEC, 0);
    if (copy < 0) { *error = errno; files_close(root); return -1; }
    int original = files_walk(copy, slot->path, size, error, slot);
    size_t length = strlen(slot->path);
    if (original < 0 || slot->directory || length > FILES_PATH - 3) { files_close(root); return original; }
    char path[FILES_PATH + 1];
    memcpy(path, slot->path, length); memcpy(path + length, ".gz", 4);
    struct files_slot candidate = {0};
    int64_t candidate_size = 0;
    int candidate_error = 0;
    int fd = files_walk(root, path, &candidate_size, &candidate_error, &candidate);
    if (fd < 0) return original;
    if (!files_gzip_fresh(slot, &candidate)) { files_close(fd); return original; }
    files_close(original);
    slot->modified_seconds = candidate.modified_seconds;
    slot->modified_nanoseconds = candidate.modified_nanoseconds;
    slot->device = candidate.device; slot->inode = candidate.inode;
    slot->observed_seconds = candidate.observed_seconds;
    slot->compressed = 1; *size = candidate_size;
    return fd;
}

static int files_list_job(int fd, struct files_slot *slot) {
    int copy = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (copy < 0) return errno;
    DIR *dir = fdopendir(copy);
    if (!dir) { int error = errno; files_close(copy); return error; }
    rewinddir(dir);
    int error = 0;
    int64_t scanned = 0, used = 0;
    for (;;) {
        errno = 0;
        struct dirent *entry = readdir(dir);
        if (!entry) { error = errno; break; }
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        if (++scanned > slot->entries_max) { error = EOVERFLOW; break; }
        size_t length = strlen(entry->d_name);
        if (!length || length > 255) { error = EOVERFLOW; break; }
        struct stat metadata;
        if (fstatat(fd, entry->d_name, &metadata, AT_SYMLINK_NOFOLLOW) < 0) { error = errno; break; }
        if (!S_ISREG(metadata.st_mode) && !S_ISDIR(metadata.st_mode)) continue;
        if ((int64_t)length + 3 > slot->listing_max - used) { error = EOVERFLOW; break; }
        slot->listing[used++] = S_ISDIR(metadata.st_mode) ? 2 : 1;
        slot->listing[used++] = (uint8_t)length;
        slot->listing[used++] = (uint8_t)(length >> 8);
        memcpy(slot->listing + used, entry->d_name, length); used += (int64_t)length;
    }
    closedir(dir);
    if (!error) { slot->listing_count = used; slot->listing_ready = 1; }
    return error;
}

#endif
