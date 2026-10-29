// Deterministic interrupted readiness call. Test-only signal installation is restored.
#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#endif
#include <stdint.h>
#include <signal.h>
#include <sys/time.h>
#include <sys/socket.h>

typedef struct { int32_t *data; int64_t len; } silly_ints;
extern int64_t silly_native_poll(silly_ints, silly_ints, silly_ints, int32_t);

static void interrupted(int signal_number) { (void)signal_number; }

int64_t silly_test_interrupt_poll(void) {
    struct sigaction action = {0}, previous;
    action.sa_handler = interrupted;
    sigemptyset(&action.sa_mask);
    if (sigaction(SIGALRM, &action, &previous) < 0) return 0;
    struct itimerval timer = {0}, previous_timer;
    timer.it_value.tv_usec = 10000;
    if (setitimer(ITIMER_REAL, &timer, &previous_timer) < 0) {
        sigaction(SIGALRM, &previous, 0);
        return 0;
    }
    silly_ints empty = {0, 0};
    int64_t result = silly_native_poll(empty, empty, empty, 1000);
    setitimer(ITIMER_REAL, &previous_timer, 0);
    sigaction(SIGALRM, &previous, 0);
    return result;
}

int32_t silly_test_reset_on_close(int32_t fd) {
    struct linger immediate = {1, 0};
    return setsockopt(fd, SOL_SOCKET, SO_LINGER, &immediate, sizeof immediate);
}
