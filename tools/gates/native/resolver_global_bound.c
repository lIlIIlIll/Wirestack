#define _POSIX_C_SOURCE 200809L

#include "wirestack_resolver.h"

#include <netdb.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <time.h>

#define EXPECTED_POOL_LIMIT UINT64_C(8)

static pthread_mutex_t block_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t block_condition = PTHREAD_COND_INITIALIZER;
static uint64_t entered_calls = 0u;
static int release_calls = 0;

int __wrap_getaddrinfo(
    const char *node,
    const char *service,
    const struct addrinfo *hints,
    struct addrinfo **results
) {
    (void)node;
    (void)service;
    (void)hints;
    *results = NULL;
    pthread_mutex_lock(&block_mutex);
    entered_calls++;
    pthread_cond_broadcast(&block_condition);
    while (!release_calls) {
        pthread_cond_wait(&block_condition, &block_mutex);
    }
    pthread_mutex_unlock(&block_mutex);
    return EAI_AGAIN;
}

static int wait_for_entered(uint64_t expected) {
    struct timespec deadline;
    if (clock_gettime(CLOCK_REALTIME, &deadline) != 0) {
        return 0;
    }
    deadline.tv_sec += 5;
    pthread_mutex_lock(&block_mutex);
    while (entered_calls < expected) {
        if (pthread_cond_timedwait(&block_condition, &block_mutex, &deadline) != 0) {
            pthread_mutex_unlock(&block_mutex);
            return 0;
        }
    }
    pthread_mutex_unlock(&block_mutex);
    return 1;
}

static void unblock_calls(void) {
    pthread_mutex_lock(&block_mutex);
    release_calls = 1;
    pthread_cond_broadcast(&block_condition);
    pthread_mutex_unlock(&block_mutex);
}

int main(void) {
    uint64_t pools[EXPECTED_POOL_LIMIT] = {0u};
    uint64_t jobs[EXPECTED_POOL_LIMIT] = {0u};
    int64_t native_code = 0;
    for (uint64_t index = 0u; index < EXPECTED_POOL_LIMIT; index++) {
        if (wirestack_resolver_pool_create(
                1u, 1u, &pools[index], &native_code
            ) != WIRESTACK_RESOLVER_OK) {
            return 10;
        }
        if (wirestack_resolver_submit(
                pools[index], "blocked.invalid", NULL,
                WIRESTACK_RESOLVER_FAMILY_ANY, 1u, &jobs[index]
            ) != WIRESTACK_RESOLVER_OK) {
            return 11;
        }
    }
    if (!wait_for_entered(EXPECTED_POOL_LIMIT)) {
        return 12;
    }
    for (uint64_t index = 0u; index < EXPECTED_POOL_LIMIT; index++) {
        wirestack_resolver_job_release(jobs[index]);
        if (wirestack_resolver_pool_destroy(pools[index]) != WIRESTACK_RESOLVER_OK) {
            return 13;
        }
    }

    uint64_t rejected = 0u;
    if (wirestack_resolver_pool_create(
            1u, 1u, &rejected, &native_code
        ) != WIRESTACK_RESOLVER_OVERLOADED ||
        rejected != 0u) {
        return 14;
    }

    unblock_calls();
    struct timespec pause = {.tv_sec = 0, .tv_nsec = 1000000L};
    uint64_t recovered = 0u;
    for (uint64_t attempt = 0u; attempt < 5000u; attempt++) {
        int32_t status = wirestack_resolver_pool_create(
            1u, 1u, &recovered, &native_code
        );
        if (status == WIRESTACK_RESOLVER_OK) {
            if (wirestack_resolver_pool_destroy(recovered) != WIRESTACK_RESOLVER_OK) {
                return 15;
            }
            printf("GLOBAL_POOL_BOUND PASS live_pool_limit=%llu\n",
                (unsigned long long)EXPECTED_POOL_LIMIT);
            return 0;
        }
        if (status != WIRESTACK_RESOLVER_OVERLOADED) {
            return 16;
        }
        nanosleep(&pause, NULL);
    }
    return 17;
}
