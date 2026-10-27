// Every delivered test signal runs in a fresh exec child, never the invoking test/agent process.
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <unistd.h>
#ifdef __APPLE__
#include <mach-o/dyld.h>
#endif

static volatile sig_atomic_t prior_count;
static void prior_handler(int signal_number) { (void)signal_number; prior_count++; }

int32_t silly_signal_test_mode(void) {
    const char *mode = getenv("SILLY_SIGNAL_TEST_CHILD");
    return mode ? atoi(mode) : 0;
}

int32_t silly_signal_test_previous(void) {
    if (!silly_signal_test_mode()) return -1;
    struct sigaction action = {0};
    action.sa_handler = prior_handler;
    sigemptyset(&action.sa_mask);
    if (sigaction(SIGINT, &action, NULL) < 0 || sigaction(SIGTERM, &action, NULL) < 0) return -1;
    prior_count = 0;
    return 0;
}

int32_t silly_signal_test_raise(int32_t mode) {
    if (!silly_signal_test_mode()) return -1;
    return raise(mode == 1 ? SIGINT : SIGTERM);
}

int32_t silly_signal_test_prior_count(void) { return prior_count; }

int32_t silly_signal_test_child(int32_t mode) {
    if (silly_signal_test_mode() || (mode != 1 && mode != 2)) return -1;
    char path[4096];
#ifdef __APPLE__
    uint32_t length = sizeof path;
    if (_NSGetExecutablePath(path, &length) != 0) return -1;
#else
    ssize_t length = readlink("/proc/self/exe", path, sizeof path - 1);
    if (length <= 0) return -1;
    path[length] = 0;
#endif
    pid_t child = fork();
    if (child < 0) return -1;
    if (!child) {
        if (setenv("SILLY_SIGNAL_TEST_CHILD", mode == 1 ? "1" : "2", 1) != 0) _exit(120);
        execl(path, path, (char *)NULL);
        _exit(121);
    }
    int status;
    pid_t result;
    do { result = waitpid(child, &status, 0); } while (result < 0 && errno == EINTR);
    if (result != child || !WIFEXITED(status)) return -1;
    return WEXITSTATUS(status);
}

static struct sigaction adapter_term;
int32_t silly_signal_test_conflict(void) {
    if (!silly_signal_test_mode()) return -1;
    struct sigaction action = {0};
    action.sa_handler = prior_handler;
    sigemptyset(&action.sa_mask);
    return sigaction(SIGTERM, &action, &adapter_term);
}

int32_t silly_signal_test_repair(void) {
    if (!silly_signal_test_mode()) return -1;
    return sigaction(SIGTERM, &adapter_term, NULL);
}
