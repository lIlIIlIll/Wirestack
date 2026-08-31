#ifndef WIRESTACK_POC_CANCEL_H
#define WIRESTACK_POC_CANCEL_H

#include <stdint.h>

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

static int poc_cancel_trigger_and_wait(PocCancelGate *gate, uint64_t *latency_us) {
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
    while (ok && !gate->finished) {
        if (!SleepConditionVariableCS(
                &gate->changed, &gate->lock,
                (DWORD)(POC_CANCELLATION_WAKE_BOUND_US / 1000ULL))) {
            ok = 0;
            break;
        }
    }
    *latency_us = poc_monotonic_us() - started;
    LeaveCriticalSection(&gate->lock);
    return ok && *latency_us <= POC_CANCELLATION_WAKE_BOUND_US;
}

static int poc_thread_start(PocThread *thread,
                            PocThreadRoutine routine,
                            void *argument) {
    *thread = CreateThread(NULL, 0, routine, argument, 0, NULL);
    return *thread != NULL;
}

static int poc_thread_join(PocThread thread) {
    DWORD result = WaitForSingleObject(thread, INFINITE);
    CloseHandle(thread);
    return result == WAIT_OBJECT_0;
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

static struct timespec poc_realtime_deadline(uint64_t timeout_us) {
    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_sec += (time_t)(timeout_us / 1000000ULL);
    deadline.tv_nsec += (long)((timeout_us % 1000000ULL) * 1000ULL);
    if (deadline.tv_nsec >= 1000000000L) {
        deadline.tv_sec++;
        deadline.tv_nsec -= 1000000000L;
    }
    return deadline;
}

static int poc_cancel_gate_init(PocCancelGate *gate) {
    if (pthread_mutex_init(&gate->lock, NULL) != 0) return 0;
    if (pthread_cond_init(&gate->changed, NULL) != 0) {
        pthread_mutex_destroy(&gate->lock);
        return 0;
    }
    gate->waiting = 0;
    gate->cancelled = 0;
    gate->finished = 0;
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

static int poc_cancel_trigger_and_wait(PocCancelGate *gate, uint64_t *latency_us) {
    int ok = 1;
    struct timespec start_deadline = poc_realtime_deadline(
        (uint64_t)POC_CANCELLATION_START_TIMEOUT_MS * 1000ULL);
    pthread_mutex_lock(&gate->lock);
    while (!gate->waiting && !gate->finished) {
        int result = pthread_cond_timedwait(
            &gate->changed, &gate->lock, &start_deadline);
        if (result == ETIMEDOUT) {
            ok = 0;
            break;
        }
        if (result != 0) {
            ok = 0;
            break;
        }
    }
    uint64_t started = poc_monotonic_us();
    gate->cancelled = 1;
    pthread_cond_broadcast(&gate->changed);
    struct timespec finish_deadline = poc_realtime_deadline(
        POC_CANCELLATION_WAKE_BOUND_US);
    while (ok && !gate->finished) {
        int result = pthread_cond_timedwait(
            &gate->changed, &gate->lock, &finish_deadline);
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
    return ok && *latency_us <= POC_CANCELLATION_WAKE_BOUND_US;
}

static int poc_thread_start(PocThread *thread,
                            PocThreadRoutine routine,
                            void *argument) {
    return pthread_create(thread, NULL, routine, argument) == 0;
}

static int poc_thread_join(PocThread thread) {
    return pthread_join(thread, NULL) == 0;
}
#endif

#endif
