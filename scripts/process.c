// POSIX process mechanics only. Verification policy and argv construction live in Goose.
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

extern char **environ;
typedef struct { const uint8_t *data; int64_t len; } Bytes;
typedef struct { int64_t pid, state, code, error; } Result;
static pid_t children[16];
static volatile sig_atomic_t cancelled;
static int initialized;

static int64_t monotonic_ms(void) {
    struct timespec value;
    if (clock_gettime(CLOCK_MONOTONIC, &value)) return -1;
    return (int64_t)value.tv_sec * 1000 + value.tv_nsec / 1000000;
}
static void interrupted(int signal_number) { cancelled = signal_number; }
static void forget(pid_t pid) {
    for (int i = 0; i < 16; i++) if (children[i] == pid) children[i] = 0;
}
static void terminate(pid_t pid) {
    if (pid <= 0) return;
    kill(-pid, SIGTERM);
    struct timespec pause = {0, 10000000};
    int status;
    for (int i = 0; i < 100; i++) {
        pid_t done = waitpid(pid, &status, WNOHANG);
        if (done == pid || (done < 0 && errno == ECHILD)) {
            // A test controller may have exited while leaving its child server alive.
            kill(-pid, SIGKILL);
            forget(pid);
            return;
        }
        nanosleep(&pause, NULL);
    }
    kill(-pid, SIGKILL);
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
    forget(pid);
}
static void cleanup(void) {
    for (int i = 0; i < 16; i++) if (children[i] > 0) terminate(children[i]);
}
static void initialize(void) {
    if (initialized) return;
    initialized = 1;
    struct sigaction action;
    memset(&action, 0, sizeof action);
    action.sa_handler = interrupted;
    sigemptyset(&action.sa_mask);
    sigaction(SIGINT, &action, NULL);
    sigaction(SIGTERM, &action, NULL);
    atexit(cleanup);
}
static char *copy_string(Bytes value, int64_t cap) {
    if (value.len < 0 || value.len > cap || memchr(value.data, 0, (size_t)value.len)) return NULL;
    char *text = malloc((size_t)value.len + 1);
    if (!text) return NULL;
    memcpy(text, value.data, (size_t)value.len);
    text[value.len] = 0;
    return text;
}
// Resolve PATH in the parent. execve never interprets executable text as shell code.
static int executable_path(char *output, size_t cap, const char *program, const char *cwd) {
    char directory[8192];
    if (cwd[0] == '/') {
        if (strlen(cwd) >= sizeof directory) return ENAMETOOLONG;
        strcpy(directory, cwd);
    } else {
        char parent[4096];
        if (!getcwd(parent, sizeof parent)) return errno;
        if (snprintf(directory, sizeof directory, "%s/%s", parent, cwd) >= (int)sizeof directory) return ENAMETOOLONG;
    }
    if (strchr(program, '/')) {
        int length = program[0] == '/' ? snprintf(output, cap, "%s", program)
            : snprintf(output, cap, "%s/%s", directory, program);
        return length < 0 || (size_t)length >= cap ? ENAMETOOLONG : 0;
    }
    const char *path = getenv("PATH");
    if (!path) path = "/usr/bin:/bin";
    const char *cursor = path;
    int previous = ENOENT;
    while (1) {
        const char *end = strchr(cursor, ':');
        size_t length = end ? (size_t)(end - cursor) : strlen(cursor);
        if (length + strlen(program) + 2 < cap) {
            int written = length && cursor[0] == '/'
                ? snprintf(output, cap, "%.*s/%s", (int)length, cursor, program)
                : snprintf(output, cap, "%s/%.*s%s%s", directory, (int)length, cursor, length ? "/" : "", program);
            if (written < 0 || (size_t)written >= cap) return ENAMETOOLONG;
            if (access(output, X_OK) == 0) return 0;
            if (errno == EACCES) previous = EACCES;
        }
        if (!end) break;
        cursor = end + 1;
    }
    return previous;
}
// The runner is single-threaded. All allocation/argv/path work precedes fork;
// child setup makes no allocations before execve/_exit; the runner never forks a worker thread.
// An errno pipe distinguishes exec failure from a real program exiting 127,
// including Linux emulators whose posix_spawn reports both identically.
static int spawn_direct(pid_t *pid, char **argv, const char *cwd, const char *log) {
    char executable[8192];
    int error = executable_path(executable, sizeof executable, argv[0], cwd);
    if (error) return error;
    int output = open(log, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
    if (output < 0) return errno;
    int report[2];
    if (pipe(report)) { error = errno; close(output); return error; }
    if (fcntl(report[0], F_SETFD, FD_CLOEXEC) || fcntl(report[1], F_SETFD, FD_CLOEXEC)) {
        error = errno; close(output); close(report[0]); close(report[1]); return error;
    }
    sigset_t empty;
    sigemptyset(&empty);
    struct sigaction defaults;
    memset(&defaults, 0, sizeof defaults);
    defaults.sa_handler = SIG_DFL;
    sigemptyset(&defaults.sa_mask);
    pid_t child = fork();
    if (child < 0) {
        error = errno; close(output); close(report[0]); close(report[1]); return error;
    }
    if (child == 0) {
        close(report[0]);
        if (setpgid(0, 0) || chdir(cwd) || dup2(output, 1) < 0 || dup2(output, 2) < 0) goto child_error;
        close(output);
        if (sigprocmask(SIG_SETMASK, &empty, NULL)
            || sigaction(SIGINT, &defaults, NULL) || sigaction(SIGTERM, &defaults, NULL)
            || sigaction(SIGPIPE, &defaults, NULL) || sigaction(SIGXFSZ, &defaults, NULL)) goto child_error;
        execve(executable, argv, environ);
child_error:
        error = errno;
        while (write(report[1], &error, sizeof error) < 0 && errno == EINTR) {}
        _exit(127);
    }
    close(output); close(report[1]);
    ssize_t got;
    do { got = read(report[0], &error, sizeof error); } while (got < 0 && errno == EINTR);
    close(report[0]);
    if (got != 0) {
        if (got < 0) error = errno;
        int status;
        while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
        return error ? error : EIO;
    }
    *pid = child;
    return 0;
}
void silly_check_spawn(Bytes packed, Bytes cwd, Bytes log, Result *result) {
    initialize();
    *result = (Result){0, 3, -1, EINVAL};
    if (cancelled || packed.len <= 1 || packed.len > 65536 || packed.data[packed.len - 1]) return;
    int slot = 0;
    while (slot < 16 && children[slot]) slot++;
    if (slot == 16) { result->error = EAGAIN; return; }
    char *directory = copy_string(cwd, 4096), *output = copy_string(log, 4096);
    char *storage = malloc((size_t)packed.len);
    if (!directory || !output || !storage) { free(directory); free(output); free(storage); return; }
    memcpy(storage, packed.data, (size_t)packed.len);
    char *argv[257];
    size_t offset = 0;
    int count = 0;
    while (offset < (size_t)packed.len && count < 256) {
        argv[count++] = storage + offset;
        offset += strlen(storage + offset) + 1;
    }
    argv[count] = NULL;
    if (offset != (size_t)packed.len || !count || !argv[0][0]) goto release;
    pid_t pid = 0;
    int error = spawn_direct(&pid, argv, directory, output);
    result->error = error;
    if (!error) { children[slot] = pid; *result = (Result){pid, 0, -1, 0}; }
release:
    free(directory); free(output); free(storage);
}
void silly_check_poll(Result *result) {
    if (result->state != 0 || result->pid <= 0) return;
    int status;
    pid_t done = waitpid((pid_t)result->pid, &status, WNOHANG);
    if (done == 0 || (done < 0 && errno == EINTR)) return;
    forget((pid_t)result->pid);
    if (done < 0) { result->state = 3; result->error = errno; return; }
    result->state = WIFEXITED(status) ? 1 : 2;
    result->code = WIFEXITED(status) ? WEXITSTATUS(status) : WTERMSIG(status);
    kill(-(pid_t)result->pid, SIGKILL);
}
void silly_check_wait(Result *result, int64_t timeout_ms) {
    int64_t start = monotonic_ms();
    struct timespec pause = {0, 10000000};
    while (result->state == 0) {
        silly_check_poll(result);
        if (result->state) break;
        int64_t now = monotonic_ms();
        if (cancelled || start < 0 || now < 0 || now - start >= timeout_ms) {
            terminate((pid_t)result->pid);
            result->state = cancelled ? 5 : 4;
            result->code = cancelled;
            break;
        }
        nanosleep(&pause, NULL);
    }
}
void silly_check_stop(Result *result) {
    if (result->state == 0) { terminate((pid_t)result->pid); result->state = 2; result->code = SIGTERM; }
}
void silly_check_cleanup(void) { cleanup(); }
int64_t silly_check_pid(void) { return getpid(); }

int64_t silly_check_cancelled(void) { return cancelled; }

// Bound memory used for log inspection without restricting compiler artifacts.
int64_t silly_check_read_log(Bytes path, Bytes output, int64_t tail) {
    char *name = copy_string(path, 4096);
    if (!name || output.len < 0) { free(name); return -1; }
    int fd = open(name, O_RDONLY | O_CLOEXEC);
    free(name);
    if (fd < 0) return -1;
    struct stat info;
    if (fstat(fd, &info) || info.st_size < 0 || !S_ISREG(info.st_mode)) { close(fd); return -1; }
    int64_t count = info.st_size;
    if (count > output.len) {
        if (!tail || lseek(fd, count - output.len, SEEK_SET) < 0) { close(fd); return -1; }
        count = output.len;
    }
    int64_t used = 0;
    while (used < count) {
        ssize_t got = read(fd, (uint8_t *)output.data + used, (size_t)(count - used));
        if (got < 0 && errno == EINTR) continue;
        if (got <= 0) { close(fd); return -1; }
        used += got;
    }
    close(fd);
    return used;
}
