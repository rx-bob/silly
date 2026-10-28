#define _POSIX_C_SOURCE 200809L
// Independent evidence that the process adapter reaped its direct child.
#include <errno.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
int32_t silly_check_test_reaped(int64_t pid) {
    int status;
    return waitpid((pid_t)pid, &status, WNOHANG) == -1 && errno == ECHILD;
}

int32_t silly_check_test_path(int32_t restore) {
    static char *saved;
    if (!restore) {
        const char *current = getenv("PATH");
        saved = current ? strdup(current) : NULL;
        return setenv("PATH", ".", 1) == 0;
    }
    int result = saved ? setenv("PATH", saved, 1) : unsetenv("PATH");
    free(saved); saved = NULL;
    return result == 0;
}
