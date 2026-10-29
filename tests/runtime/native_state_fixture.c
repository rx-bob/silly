// Test-only globals model multi-call DB/ZIP APIs. Individual locks expose, rather than hide,
// sequence interleaving: every API verifies the opening pthread and the exact operation stage.
#include <errno.h>
#include <pthread.h>
#include <stdint.h>
#include <time.h>

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t changed = PTHREAD_COND_INITIALIZER;
static pthread_t owner;
static int opened, stage, gate_kind, blocked, released;
static int64_t value;
static int64_t metrics[8]; // opens, closes, violations, db-start, db-done, zip-start, zip-done, failed-open
static int fail_open;

static int check(int expected) {
    if (!opened || !pthread_equal(owner, pthread_self()) || stage != expected) {
        metrics[2]++;
        return 0;
    }
    return 1;
}

static void gate(int kind) {
    if (gate_kind != kind) return;
    gate_kind = 0;
    blocked = 1;
    pthread_cond_broadcast(&changed);
    while (!released) pthread_cond_wait(&changed, &lock);
    blocked = 0;
    released = 0;
}

int32_t promptnook_contract_open(void) {
    pthread_mutex_lock(&lock);
    if (opened) {
        metrics[2]++;
        pthread_mutex_unlock(&lock);
        return -1;
    }
    if (fail_open) {
        metrics[7]++;
        pthread_mutex_unlock(&lock);
        return -1;
    }
    owner = pthread_self();
    opened = 1;
    stage = 0;
    metrics[0]++;
    pthread_mutex_unlock(&lock);
    return 0;
}

int32_t promptnook_contract_close(void) {
    pthread_mutex_lock(&lock);
    int valid = check(0);
    if (valid) { opened = 0; metrics[1]++; }
    pthread_mutex_unlock(&lock);
    return valid ? 0 : -1;
}

int32_t promptnook_contract_prepare(int64_t input) {
    pthread_mutex_lock(&lock);
    int valid = check(0);
    if (valid) { stage = 1; value = input; metrics[3]++; }
    pthread_mutex_unlock(&lock);
    return valid ? 0 : -1;
}

int32_t promptnook_contract_bind(int64_t input) {
    pthread_mutex_lock(&lock);
    int valid = check(1);
    if (valid && input != value) { metrics[2]++; valid = 0; }
    if (valid) stage = 2;
    pthread_mutex_unlock(&lock);
    return valid ? 0 : -1;
}

int32_t promptnook_contract_query(void) {
    pthread_mutex_lock(&lock);
    int valid = check(2);
    if (valid) { stage = 3; gate(1); }
    pthread_mutex_unlock(&lock);
    return valid ? 0 : -1;
}

int64_t promptnook_contract_read(void) {
    pthread_mutex_lock(&lock);
    int valid = check(3);
    int64_t result = -1;
    if (valid) { result = value * 10 + 7; stage = 0; metrics[4]++; }
    pthread_mutex_unlock(&lock);
    return result;
}

int32_t promptnook_contract_zip_reset(int64_t input) {
    pthread_mutex_lock(&lock);
    int valid = check(0);
    if (valid) { stage = 4; value = input; metrics[5]++; }
    pthread_mutex_unlock(&lock);
    return valid ? 0 : -1;
}

int32_t promptnook_contract_zip_add(int64_t input) {
    pthread_mutex_lock(&lock);
    int valid = check(4);
    if (valid && input != value) { metrics[2]++; valid = 0; }
    if (valid) { stage = 5; gate(2); }
    pthread_mutex_unlock(&lock);
    return valid ? 0 : -1;
}

int64_t promptnook_contract_zip_finish(void) {
    pthread_mutex_lock(&lock);
    int valid = check(5);
    int64_t result = -1;
    if (valid) { result = value * 100 + 3; stage = 0; metrics[6]++; }
    pthread_mutex_unlock(&lock);
    return result;
}

// Test controls are independent of the native API's owning thread.
int32_t native_test_reset(int32_t failing) {
    pthread_mutex_lock(&lock);
    if (opened || blocked) { pthread_mutex_unlock(&lock); return -1; }
    for (int i = 0; i < 8; i++) metrics[i] = 0;
    stage = gate_kind = blocked = released = 0;
    fail_open = failing;
    pthread_mutex_unlock(&lock);
    return 0;
}

int32_t native_test_arm(int32_t kind) {
    pthread_mutex_lock(&lock);
    if (blocked || gate_kind || (kind != 1 && kind != 2)) {
        pthread_mutex_unlock(&lock); return -1;
    }
    gate_kind = kind;
    pthread_mutex_unlock(&lock);
    return 0;
}

int32_t native_test_wait(int32_t timeout_ms) {
    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_sec += timeout_ms / 1000;
    deadline.tv_nsec += (timeout_ms % 1000) * 1000000L;
    if (deadline.tv_nsec >= 1000000000L) { deadline.tv_sec++; deadline.tv_nsec -= 1000000000L; }
    pthread_mutex_lock(&lock);
    int error = 0;
    while (!blocked && !error) error = pthread_cond_timedwait(&changed, &lock, &deadline);
    int ready = blocked;
    pthread_mutex_unlock(&lock);
    return ready ? 0 : -1;
}

int32_t native_test_release(void) {
    pthread_mutex_lock(&lock);
    if (!blocked) { pthread_mutex_unlock(&lock); return -1; }
    released = 1;
    pthread_cond_broadcast(&changed);
    pthread_mutex_unlock(&lock);
    return 0;
}

int64_t native_test_metric(int32_t index) {
    pthread_mutex_lock(&lock);
    int64_t result = index >= 0 && index < 8 ? metrics[index] : -1;
    pthread_mutex_unlock(&lock);
    return result;
}
