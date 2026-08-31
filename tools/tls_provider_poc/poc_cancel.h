#ifndef WIRESTACK_POC_CANCEL_H
#define WIRESTACK_POC_CANCEL_H

#include <stdint.h>
#include <stdlib.h>

#define POC_CANCELLATION_WAKE_BOUND_US 250000ULL
#define POC_CANCELLATION_START_TIMEOUT_MS 5000U

#if defined(_WIN32)
#include <windows.h>

typedef struct PocCancelGate {
    CRITICAL_SECTION lock;
    CONDITION_VARIABLE changed;
    int waiting;
    int cancelled;
    int finished;
    int joined;
    int join_ok;
} PocCancelGate;

typedef HANDLE PocThread;
typedef DWORD (WINAPI *PocThreadRoutine)(LPVOID);
#define POC_THREAD_RETURN DWORD WINAPI
#define POC_THREAD_ARGUMENT LPVOID
#define POC_THREAD_DONE return 0

static uint64_t poc_monotonic_us(void) {
    LARGE_INTEGER counter;
    LARGE_INTEGER frequency;
    QueryPerformanceCounter(&counter);
    QueryPerformanceFrequency(&frequency);
    return (uint64_t)((counter.QuadPart * 1000000ULL) / frequency.QuadPart);
}

static int poc_cancel_gate_init(PocCancelGate *gate) {
    InitializeCriticalSection(&gate->lock);
    InitializeConditionVariable(&gate->changed);
    gate->waiting = 0;
    gate->cancelled = 0;
    gate->finished = 0;
    gate->joined = 0;
    gate->join_ok = 0;
    return 1;
}

static void poc_cancel_gate_destroy(PocCancelGate *gate) {
    DeleteCriticalSection(&gate->lock);
}

static void poc_cancel_worker_wait(PocCancelGate *gate) {
    EnterCriticalSection(&gate->lock);
    gate->waiting = 1;
    WakeAllConditionVariable(&gate->changed);
    while (!gate->cancelled) {
        SleepConditionVariableCS(&gate->changed, &gate->lock, INFINITE);
    }
    gate->finished = 1;
    WakeAllConditionVariable(&gate->changed);
    LeaveCriticalSection(&gate->lock);
}

static int poc_cancel_trigger_and_join(PocCancelGate *gate, PocThread thread,
                                       uint64_t *latency_us) {
    int ok = 1;
    EnterCriticalSection(&gate->lock);
    while (!gate->waiting && !gate->finished) {
        if (!SleepConditionVariableCS(
                &gate->changed, &gate->lock,
                POC_CANCELLATION_START_TIMEOUT_MS)) {
            ok = 0;
            break;
        }
    }
    uint64_t started = poc_monotonic_us();
    gate->cancelled = 1;
    WakeAllConditionVariable(&gate->changed);
    LeaveCriticalSection(&gate->lock);
    uint64_t elapsed = poc_monotonic_us() - started;
    uint64_t remaining = elapsed < POC_CANCELLATION_WAKE_BOUND_US
        ? POC_CANCELLATION_WAKE_BOUND_US - elapsed : 0;
    DWORD wait_ms = (DWORD)((remaining + 999ULL) / 1000ULL);
    DWORD result = remaining > 0
        ? WaitForSingleObject(thread, wait_ms) : WAIT_TIMEOUT;
    *latency_us = poc_monotonic_us() - started;
    CloseHandle(thread);
    EnterCriticalSection(&gate->lock);
    gate->joined = result == WAIT_OBJECT_0;
    gate->join_ok = gate->joined;
    LeaveCriticalSection(&gate->lock);
    return ok && gate->join_ok &&
        *latency_us <= POC_CANCELLATION_WAKE_BOUND_US;
}

static int poc_thread_start(PocThread *thread,
                            PocThreadRoutine routine,
                            void *argument) {
    *thread = CreateThread(NULL, 0, routine, argument, 0, NULL);
    return *thread != NULL;
}

static int poc_cancel_join_complete(PocCancelGate *gate) {
    EnterCriticalSection(&gate->lock);
    int joined = gate->joined;
    LeaveCriticalSection(&gate->lock);
    return joined;
}

#else
#include <errno.h>
#include <pthread.h>
#include <time.h>

typedef struct PocCancelGate {
    pthread_mutex_t lock;
    pthread_cond_t changed;
    int waiting;
    int cancelled;
    int finished;
    int joined;
    int join_ok;
} PocCancelGate;

typedef pthread_t PocThread;
typedef void *(*PocThreadRoutine)(void *);
#define POC_THREAD_RETURN void *
#define POC_THREAD_ARGUMENT void *
#define POC_THREAD_DONE return NULL

static uint64_t poc_monotonic_us(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (uint64_t)now.tv_sec * 1000000ULL + (uint64_t)now.tv_nsec / 1000ULL;
}

static struct timespec poc_duration_us(uint64_t duration_us) {
    struct timespec duration;
    duration.tv_sec = (time_t)(duration_us / 1000000ULL);
    duration.tv_nsec = (long)((duration_us % 1000000ULL) * 1000ULL);
    return duration;
}

static int poc_cond_timedwait_until(PocCancelGate *gate,
                                    uint64_t monotonic_deadline_us) {
    uint64_t now = poc_monotonic_us();
    if (now >= monotonic_deadline_us) return ETIMEDOUT;
#if defined(__APPLE__)
    struct timespec remaining = poc_duration_us(monotonic_deadline_us - now);
    return pthread_cond_timedwait_relative_np(
        &gate->changed, &gate->lock, &remaining);
#else
    struct timespec deadline = poc_duration_us(monotonic_deadline_us);
    return pthread_cond_timedwait(&gate->changed, &gate->lock, &deadline);
#endif
}

static int poc_cancel_gate_init(PocCancelGate *gate) {
    if (pthread_mutex_init(&gate->lock, NULL) != 0) return 0;
    pthread_condattr_t attributes;
    if (pthread_condattr_init(&attributes) != 0) {
        pthread_mutex_destroy(&gate->lock);
        return 0;
    }
#if !defined(__APPLE__)
    if (pthread_condattr_setclock(&attributes, CLOCK_MONOTONIC) != 0) {
        pthread_condattr_destroy(&attributes);
        pthread_mutex_destroy(&gate->lock);
        return 0;
    }
#endif
    int cond_result = pthread_cond_init(&gate->changed, &attributes);
    pthread_condattr_destroy(&attributes);
    if (cond_result != 0) {
        pthread_mutex_destroy(&gate->lock);
        return 0;
    }
    gate->waiting = 0;
    gate->cancelled = 0;
    gate->finished = 0;
    gate->joined = 0;
    gate->join_ok = 0;
    return 1;
}

static void poc_cancel_gate_destroy(PocCancelGate *gate) {
    pthread_cond_destroy(&gate->changed);
    pthread_mutex_destroy(&gate->lock);
}

static void poc_cancel_worker_wait(PocCancelGate *gate) {
    pthread_mutex_lock(&gate->lock);
    gate->waiting = 1;
    pthread_cond_broadcast(&gate->changed);
    while (!gate->cancelled) pthread_cond_wait(&gate->changed, &gate->lock);
    gate->finished = 1;
    pthread_cond_broadcast(&gate->changed);
    pthread_mutex_unlock(&gate->lock);
}

typedef struct PocJoinRequest {
    PocCancelGate *gate;
    PocThread target;
} PocJoinRequest;

static void *poc_join_target(void *opaque) {
    PocJoinRequest *request = (PocJoinRequest *)opaque;
    PocCancelGate *gate = request->gate;
    PocThread target = request->target;
    free(request);
    int result = pthread_join(target, NULL);
    pthread_mutex_lock(&gate->lock);
    gate->joined = 1;
    gate->join_ok = result == 0;
    pthread_cond_broadcast(&gate->changed);
    pthread_mutex_unlock(&gate->lock);
    return NULL;
}

static int poc_cancel_trigger_and_join(PocCancelGate *gate, PocThread thread,
                                       uint64_t *latency_us) {
    int ok = 1;
    uint64_t start_deadline = poc_monotonic_us() +
        (uint64_t)POC_CANCELLATION_START_TIMEOUT_MS * 1000ULL;
    pthread_mutex_lock(&gate->lock);
    while (!gate->waiting && !gate->finished) {
        int result = poc_cond_timedwait_until(gate, start_deadline);
        if (result == ETIMEDOUT) {
            ok = 0;
            break;
        }
        if (result != 0) {
            ok = 0;
            break;
        }
    }
    PocJoinRequest *request = malloc(sizeof(PocJoinRequest));
    pthread_attr_t attributes;
    pthread_t joiner;
    int joiner_started = 0;
    if (request != NULL && pthread_attr_init(&attributes) == 0) {
        request->gate = gate;
        request->target = thread;
        if (pthread_attr_setdetachstate(
                &attributes, PTHREAD_CREATE_DETACHED) == 0 &&
                pthread_create(&joiner, &attributes, poc_join_target, request) == 0) {
            joiner_started = 1;
        }
        pthread_attr_destroy(&attributes);
    }
    if (!joiner_started) {
        free(request);
        ok = 0;
    }
    uint64_t started = poc_monotonic_us();
    gate->cancelled = 1;
    pthread_cond_broadcast(&gate->changed);
    uint64_t finish_deadline = started + POC_CANCELLATION_WAKE_BOUND_US;
    while (ok && !gate->joined) {
        int result = poc_cond_timedwait_until(gate, finish_deadline);
        if (result == ETIMEDOUT) {
            ok = 0;
            break;
        }
        if (result != 0) {
            ok = 0;
            break;
        }
    }
    *latency_us = poc_monotonic_us() - started;
    pthread_mutex_unlock(&gate->lock);
    return ok && gate->join_ok &&
        *latency_us <= POC_CANCELLATION_WAKE_BOUND_US;
}

static int poc_thread_start(PocThread *thread,
                            PocThreadRoutine routine,
                            void *argument) {
    return pthread_create(thread, NULL, routine, argument) == 0;
}

static int poc_cancel_join_complete(PocCancelGate *gate) {
    pthread_mutex_lock(&gate->lock);
    int joined = gate->joined;
    pthread_mutex_unlock(&gate->lock);
    return joined;
}
#endif

#endif
