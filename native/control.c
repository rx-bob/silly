// Process-local runtime identity and optional shutdown signals. No app descriptors live here.
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <limits.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdatomic.h>
#include <string.h>

static pthread_mutex_t control_lock = PTHREAD_MUTEX_INITIALIZER;
static int64_t next_epoch, active_epoch, revision, pending_submissions;
static int stage, claimed;
static pthread_t claimant;

static int owns_claim(int64_t epoch) {
    return epoch > 0 && epoch == active_epoch && claimed && pthread_equal(claimant, pthread_self());
}

int64_t silly_control_begin(void) {
    pthread_mutex_lock(&control_lock);
    int64_t result = 0;
    if (!active_epoch && next_epoch < INT64_MAX) {
        active_epoch = ++next_epoch;
        revision = pending_submissions = 0;
        stage = claimed = 0;
        result = active_epoch;
    }
    pthread_mutex_unlock(&control_lock);
    return result;
}

int32_t silly_control_stage(int64_t epoch) {
    if (!epoch) return 0;
    pthread_mutex_lock(&control_lock);
    int32_t result = epoch > 0 && epoch == active_epoch ? stage : -1;
    pthread_mutex_unlock(&control_lock);
    return result;
}

int32_t silly_control_admit(int64_t epoch) {
    return silly_control_stage(epoch) == 0;
}

// Submission permits extend the admission linearization through the actual queue publication.
int32_t silly_control_submit_begin(int64_t epoch) {
    if (!epoch) return 1;
    pthread_mutex_lock(&control_lock);
    int valid = epoch > 0 && epoch == active_epoch && stage == 0 && pending_submissions < INT64_MAX;
    if (valid) pending_submissions++;
    pthread_mutex_unlock(&control_lock);
    return valid;
}

void silly_control_submit_end(int64_t epoch) {
    if (!epoch) return;
    pthread_mutex_lock(&control_lock);
    if (epoch > 0 && epoch == active_epoch && pending_submissions > 0) pending_submissions--;
    pthread_mutex_unlock(&control_lock);
}

int64_t silly_control_submissions(int64_t epoch) {
    if (!epoch) return 0;
    pthread_mutex_lock(&control_lock);
    int64_t result = epoch > 0 && epoch == active_epoch ? pending_submissions : -1;
    pthread_mutex_unlock(&control_lock);
    return result;
}

void silly_control_advance(int64_t epoch, int32_t requested) {
    pthread_mutex_lock(&control_lock);
    if (epoch > 0 && epoch == active_epoch && requested >= 1 && requested <= 3 && stage < requested) {
        stage = requested;
    }
    pthread_mutex_unlock(&control_lock);
}

int64_t silly_control_ticket(int64_t epoch) {
    pthread_mutex_lock(&control_lock);
    int64_t result = epoch > 0 && epoch == active_epoch ? revision : -1;
    pthread_mutex_unlock(&control_lock);
    return result;
}

int32_t silly_control_claim_ticket(int64_t epoch, int64_t ticket) {
    pthread_mutex_lock(&control_lock);
    int valid = epoch > 0 && epoch == active_epoch && ticket == revision && !claimed;
    if (valid) { claimed = 1; claimant = pthread_self(); }
    pthread_mutex_unlock(&control_lock);
    return valid;
}

int32_t silly_control_claim(int64_t epoch) {
    pthread_mutex_lock(&control_lock);
    int valid = epoch > 0 && epoch == active_epoch && !claimed;
    if (valid) { claimed = 1; claimant = pthread_self(); }
    pthread_mutex_unlock(&control_lock);
    return valid;
}

int64_t silly_control_release(int64_t epoch) {
    pthread_mutex_lock(&control_lock);
    int64_t result = -1;
    if (owns_claim(epoch)) {
        claimed = 0;
        if (revision < INT64_MAX) result = ++revision;
        else stage = 3;
    }
    pthread_mutex_unlock(&control_lock);
    return result;
}

void silly_control_finish(int64_t epoch, int32_t poison) {
    pthread_mutex_lock(&control_lock);
    if (owns_claim(epoch) && (pending_submissions == 0 || poison || stage == 3)) {
        claimed = 0;
        if (poison || stage == 3) {
            stage = 3;
            // Invalidate every outstanding handle ticket, retaining the poisoned epoch.
            if (revision < INT64_MAX) revision++;
        } else {
            active_epoch = 0;
        }
    }
    pthread_mutex_unlock(&control_lock);
}

int32_t silly_control_poisoned(void) {
    pthread_mutex_lock(&control_lock);
    int32_t result = active_epoch > 0 && stage == 3;
    pthread_mutex_unlock(&control_lock);
    return result;
}

static pthread_mutex_t signal_lock = PTHREAD_MUTEX_INITIALIZER;
_Static_assert(ATOMIC_INT_LOCK_FREE == 2, "shutdown signals require lock-free int atomics");
_Static_assert(_Generic((sig_atomic_t)0, int: 1, default: 0), "sig_atomic_t must be int");
static _Atomic(sig_atomic_t) shutdown_requested;
static int64_t next_signal_token, signal_token;
static struct sigaction previous_int, previous_term;

// Async-signal-safe: no mutex, allocation, native resource, callback or wake descriptor access.
static void request_shutdown(int signal_number) {
    (void)signal_number;
    atomic_store_explicit(&shutdown_requested, 1, memory_order_relaxed);
}

int64_t silly_signals_install(void) {
    pthread_mutex_lock(&signal_lock);
    if (signal_token || next_signal_token == INT64_MAX) {
        int error = signal_token ? EBUSY : EOVERFLOW;
        pthread_mutex_unlock(&signal_lock);
        return -error;
    }
    if (sigaction(SIGINT, NULL, &previous_int) < 0 || sigaction(SIGTERM, NULL, &previous_term) < 0) {
        int error = errno;
        pthread_mutex_unlock(&signal_lock);
        return -error;
    }
    struct sigaction action;
    memset(&action, 0, sizeof action);
    action.sa_handler = request_shutdown;
    sigemptyset(&action.sa_mask);
    atomic_store_explicit(&shutdown_requested, 0, memory_order_relaxed);
    if (sigaction(SIGINT, &action, NULL) < 0) {
        int error = errno;
        pthread_mutex_unlock(&signal_lock);
        return -error;
    }
    if (sigaction(SIGTERM, &action, NULL) < 0) {
        int error = errno;
        sigaction(SIGINT, &previous_int, NULL);
        pthread_mutex_unlock(&signal_lock);
        return -error;
    }
    signal_token = ++next_signal_token;
    int64_t result = signal_token;
    pthread_mutex_unlock(&signal_lock);
    return result;
}

int32_t silly_signals_requested(int64_t token) {
    pthread_mutex_lock(&signal_lock);
    int32_t result = token > 0 && token == signal_token
        && atomic_load_explicit(&shutdown_requested, memory_order_relaxed);
    pthread_mutex_unlock(&signal_lock);
    return result;
}

int32_t silly_signals_uninstall(int64_t token) {
    pthread_mutex_lock(&signal_lock);
    if (token <= 0 || token != signal_token) {
        pthread_mutex_unlock(&signal_lock);
        return EINVAL;
    }
    struct sigaction current_int, current_term;
    if (sigaction(SIGINT, NULL, &current_int) < 0 || sigaction(SIGTERM, NULL, &current_term) < 0) {
        int error = errno;
        pthread_mutex_unlock(&signal_lock);
        return error;
    }
    if (current_int.sa_handler != request_shutdown || current_term.sa_handler != request_shutdown
        || (current_int.sa_flags & SA_SIGINFO) || (current_term.sa_flags & SA_SIGINFO)) {
        pthread_mutex_unlock(&signal_lock);
        return EBUSY;
    }
    if (sigaction(SIGINT, &previous_int, NULL) < 0 || sigaction(SIGTERM, &previous_term, NULL) < 0) {
        int error = errno;
        pthread_mutex_unlock(&signal_lock);
        return error;
    }
    signal_token = 0;
    pthread_mutex_unlock(&signal_lock);
    return 0;
}
