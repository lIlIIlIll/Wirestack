#define _POSIX_C_SOURCE 200809L

#include "wirestack_resolver.h"

#include <arpa/inet.h>
#include <errno.h>
#include <netdb.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>

#define WIRESTACK_RESOLVER_POOL_MAGIC UINT64_C(0x5753524553503031)
#define WIRESTACK_RESOLVER_JOB_MAGIC UINT64_C(0x57535245534a3031)
#define WIRESTACK_RESOLVER_MAXIMUM_WORKERS UINT64_C(32)
#define WIRESTACK_RESOLVER_MAXIMUM_QUEUE UINT64_C(1024)
#define WIRESTACK_RESOLVER_MAXIMUM_RESULTS UINT64_C(1024)
#define WIRESTACK_RESOLVER_MAXIMUM_HOST_BYTES UINT64_C(253)
#define WIRESTACK_RESOLVER_MAXIMUM_SERVICE_BYTES UINT64_C(63)
#define WIRESTACK_RESOLVER_ADDRESS_BYTES UINT64_C(16)
#define WIRESTACK_RESOLVER_MAXIMUM_LIVE_POOLS UINT64_C(8)
#define WIRESTACK_RESOLVER_MAXIMUM_LIVE_WORKERS UINT64_C(64)

enum wirestack_resolver_job_state {
    WIRESTACK_RESOLVER_JOB_QUEUED = 0,
    WIRESTACK_RESOLVER_JOB_RUNNING = 1,
    WIRESTACK_RESOLVER_JOB_COMPLETE = 2
};

struct wirestack_resolver_address {
    int32_t family;
    uint32_t scope_id;
    uint8_t bytes[WIRESTACK_RESOLVER_ADDRESS_BYTES];
};

struct wirestack_resolver_pool;

struct wirestack_resolver_job {
    uint64_t magic;
    struct wirestack_resolver_pool *pool;
    struct wirestack_resolver_job *next;
    char *host;
    char *service;
    struct wirestack_resolver_address *addresses;
    uint64_t maximum_results;
    uint64_t result_count;
    int64_t native_code;
    int32_t family;
    int32_t result;
    int32_t state;
    int32_t references;
    int caller_released;
};

struct wirestack_resolver_pool {
    uint64_t magic;
    pthread_mutex_t mutex;
    pthread_cond_t work_available;
    pthread_cond_t idle;
    pthread_t *workers;
    pthread_t reaper;
    struct wirestack_resolver_job *queue_head;
    struct wirestack_resolver_job *queue_tail;
    uint64_t worker_count;
    uint64_t queue_capacity;
    uint64_t active_jobs;
    uint64_t queued_jobs;
    uint64_t running_jobs;
    uint64_t peak_active_jobs;
    uint64_t peak_queued_jobs;
    uint64_t submitted_jobs;
    uint64_t completed_jobs;
    uint64_t rejected_jobs;
    int accepting;
    int stopping;
    int capacity_reserved;
};

static pthread_mutex_t resolver_capacity_mutex = PTHREAD_MUTEX_INITIALIZER;
static uint64_t resolver_live_pools = 0u;
static uint64_t resolver_live_workers = 0u;

static int reserve_pool_capacity(struct wirestack_resolver_pool *pool) {
    int reserved = 0;
    pthread_mutex_lock(&resolver_capacity_mutex);
    if (resolver_live_pools < WIRESTACK_RESOLVER_MAXIMUM_LIVE_POOLS &&
        pool->worker_count <= WIRESTACK_RESOLVER_MAXIMUM_LIVE_WORKERS - resolver_live_workers) {
        resolver_live_pools++;
        resolver_live_workers += pool->worker_count;
        pool->capacity_reserved = 1;
        reserved = 1;
    }
    pthread_mutex_unlock(&resolver_capacity_mutex);
    return reserved;
}

static void release_pool_capacity(struct wirestack_resolver_pool *pool) {
    if (!pool->capacity_reserved) {
        return;
    }
    pthread_mutex_lock(&resolver_capacity_mutex);
    resolver_live_pools--;
    resolver_live_workers -= pool->worker_count;
    pool->capacity_reserved = 0;
    pthread_mutex_unlock(&resolver_capacity_mutex);
}

static void free_pool(struct wirestack_resolver_pool *pool) {
    release_pool_capacity(pool);
    pool->magic = 0u;
    pthread_cond_destroy(&pool->idle);
    pthread_cond_destroy(&pool->work_available);
    pthread_mutex_destroy(&pool->mutex);
    free(pool->workers);
    free(pool);
}

static char *copy_bounded_string(const char *value, uint64_t maximum) {
    if (value == NULL) {
        return NULL;
    }
    size_t length = strnlen(value, (size_t)maximum + 1u);
    if (length == 0u || length > (size_t)maximum) {
        return NULL;
    }
    char *copy = (char *)malloc(length + 1u);
    if (copy == NULL) {
        return NULL;
    }
    memcpy(copy, value, length + 1u);
    return copy;
}

static int valid_family(int32_t family) {
    return family == WIRESTACK_RESOLVER_FAMILY_ANY ||
        family == WIRESTACK_RESOLVER_FAMILY_IPV4 ||
        family == WIRESTACK_RESOLVER_FAMILY_IPV6;
}

static int native_family(int32_t family) {
    if (family == WIRESTACK_RESOLVER_FAMILY_IPV4) {
        return AF_INET;
    }
    if (family == WIRESTACK_RESOLVER_FAMILY_IPV6) {
        return AF_INET6;
    }
    return AF_UNSPEC;
}

static int32_t classify_getaddrinfo_error(int code) {
    switch (code) {
        case 0:
            return WIRESTACK_RESOLVER_RESULT_SUCCESS;
        case EAI_NONAME:
            return WIRESTACK_RESOLVER_RESULT_NAME_NOT_FOUND;
#if defined(EAI_NODATA) && EAI_NODATA != EAI_NONAME
        case EAI_NODATA:
            return WIRESTACK_RESOLVER_RESULT_NO_DATA;
#endif
        case EAI_AGAIN:
            return WIRESTACK_RESOLVER_RESULT_TEMPORARY_FAILURE;
        case EAI_FAMILY:
            return WIRESTACK_RESOLVER_RESULT_UNSUPPORTED_FAMILY;
        case EAI_BADFLAGS:
        case EAI_SERVICE:
        case EAI_SOCKTYPE:
            return WIRESTACK_RESOLVER_RESULT_INVALID_NAME;
        default:
            return WIRESTACK_RESOLVER_RESULT_SYSTEM_FAILURE;
    }
}

static void free_job_locked(struct wirestack_resolver_job *job) {
    struct wirestack_resolver_pool *pool = job->pool;
    job->magic = 0u;
    free(job->addresses);
    free(job->service);
    free(job->host);
    free(job);
    pool->active_jobs--;
    pthread_cond_broadcast(&pool->idle);
}

static void release_reference_locked(struct wirestack_resolver_job *job) {
    job->references--;
    if (job->references == 0) {
        free_job_locked(job);
    }
}

static void resolve_job(struct wirestack_resolver_job *job) {
    struct addrinfo hints;
    struct addrinfo *results = NULL;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = native_family(job->family);
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_flags = AI_ADDRCONFIG;

    errno = 0;
    int status = getaddrinfo(job->host, job->service, &hints, &results);
    int saved_errno = errno;
    job->result = classify_getaddrinfo_error(status);
    job->native_code = status == EAI_SYSTEM ? (int64_t)saved_errno : (int64_t)status;
    job->result_count = 0u;

    if (status == 0) {
        for (struct addrinfo *current = results;
             current != NULL && job->result_count < job->maximum_results;
             current = current->ai_next) {
            struct wirestack_resolver_address *destination =
                &job->addresses[job->result_count];
            memset(destination, 0, sizeof(*destination));
            if (current->ai_family == AF_INET &&
                current->ai_addrlen >= (socklen_t)sizeof(struct sockaddr_in)) {
                const struct sockaddr_in *address =
                    (const struct sockaddr_in *)current->ai_addr;
                destination->family = WIRESTACK_RESOLVER_FAMILY_IPV4;
                memcpy(destination->bytes, &address->sin_addr, 4u);
                job->result_count++;
            } else if (current->ai_family == AF_INET6 &&
                       current->ai_addrlen >= (socklen_t)sizeof(struct sockaddr_in6)) {
                const struct sockaddr_in6 *address =
                    (const struct sockaddr_in6 *)current->ai_addr;
                destination->family = WIRESTACK_RESOLVER_FAMILY_IPV6;
                destination->scope_id = address->sin6_scope_id;
                memcpy(destination->bytes, &address->sin6_addr, 16u);
                job->result_count++;
            }
        }
        if (job->result_count == 0u) {
            job->result = WIRESTACK_RESOLVER_RESULT_NO_DATA;
        }
    }
    if (results != NULL) {
        freeaddrinfo(results);
    }
}

static void *resolver_worker(void *argument) {
    struct wirestack_resolver_pool *pool = (struct wirestack_resolver_pool *)argument;
    for (;;) {
        pthread_mutex_lock(&pool->mutex);
        while (pool->queue_head == NULL && !pool->stopping) {
            pthread_cond_wait(&pool->work_available, &pool->mutex);
        }
        if (pool->queue_head == NULL && pool->stopping) {
            pthread_mutex_unlock(&pool->mutex);
            return NULL;
        }
        struct wirestack_resolver_job *job = pool->queue_head;
        pool->queue_head = job->next;
        if (pool->queue_head == NULL) {
            pool->queue_tail = NULL;
        }
        job->next = NULL;
        pool->queued_jobs--;
        if (job->caller_released) {
            job->state = WIRESTACK_RESOLVER_JOB_COMPLETE;
            job->result = WIRESTACK_RESOLVER_RESULT_SYSTEM_FAILURE;
            pool->completed_jobs++;
            release_reference_locked(job);
            pthread_mutex_unlock(&pool->mutex);
            continue;
        }
        job->state = WIRESTACK_RESOLVER_JOB_RUNNING;
        pool->running_jobs++;
        pthread_mutex_unlock(&pool->mutex);

        resolve_job(job);

        pthread_mutex_lock(&pool->mutex);
        pool->running_jobs--;
        job->state = WIRESTACK_RESOLVER_JOB_COMPLETE;
        pool->completed_jobs++;
        release_reference_locked(job);
        pthread_mutex_unlock(&pool->mutex);
    }
}

/*
 * Blocking libc/NSS resolver calls cannot be interrupted portably. Closing a
 * public resolver therefore quarantines this bounded pool and lets this reaper
 * reclaim it only after every worker and caller-held job reference is gone.
 * Process-wide live-pool and worker reservations bound quarantined resources;
 * new pools fail closed while blocked calls hold that capacity.
 */
static void *resolver_reaper(void *argument) {
    struct wirestack_resolver_pool *pool = (struct wirestack_resolver_pool *)argument;
    pthread_mutex_lock(&pool->mutex);
    while (!pool->stopping) {
        pthread_cond_wait(&pool->idle, &pool->mutex);
    }
    pthread_mutex_unlock(&pool->mutex);

    for (uint64_t index = 0u; index < pool->worker_count; index++) {
        pthread_join(pool->workers[index], NULL);
    }

    pthread_mutex_lock(&pool->mutex);
    while (pool->active_jobs != 0u) {
        pthread_cond_wait(&pool->idle, &pool->mutex);
    }
    pthread_mutex_unlock(&pool->mutex);
    free_pool(pool);
    return NULL;
}

int32_t wirestack_resolver_pool_create(
    uint64_t worker_count,
    uint64_t queue_capacity,
    uint64_t *out_pool_handle,
    int64_t *out_native_code
) {
    if (out_pool_handle == NULL || out_native_code == NULL || worker_count == 0u ||
        worker_count > WIRESTACK_RESOLVER_MAXIMUM_WORKERS ||
        queue_capacity == 0u || queue_capacity > WIRESTACK_RESOLVER_MAXIMUM_QUEUE) {
        return WIRESTACK_RESOLVER_INVALID_ARGUMENT;
    }
    *out_pool_handle = 0u;
    *out_native_code = 0;
    struct wirestack_resolver_pool *pool =
        (struct wirestack_resolver_pool *)calloc(1u, sizeof(*pool));
    if (pool == NULL) {
        return WIRESTACK_RESOLVER_OUT_OF_MEMORY;
    }
    pool->workers = (pthread_t *)calloc((size_t)worker_count, sizeof(pthread_t));
    if (pool->workers == NULL) {
        free(pool);
        return WIRESTACK_RESOLVER_OUT_OF_MEMORY;
    }
    if (pthread_mutex_init(&pool->mutex, NULL) != 0) {
        free(pool->workers);
        free(pool);
        return WIRESTACK_RESOLVER_OUT_OF_MEMORY;
    }
    if (pthread_cond_init(&pool->work_available, NULL) != 0) {
        pthread_mutex_destroy(&pool->mutex);
        free(pool->workers);
        free(pool);
        return WIRESTACK_RESOLVER_OUT_OF_MEMORY;
    }
    if (pthread_cond_init(&pool->idle, NULL) != 0) {
        pthread_cond_destroy(&pool->work_available);
        pthread_mutex_destroy(&pool->mutex);
        free(pool->workers);
        free(pool);
        return WIRESTACK_RESOLVER_OUT_OF_MEMORY;
    }
    pool->magic = WIRESTACK_RESOLVER_POOL_MAGIC;
    pool->worker_count = worker_count;
    pool->queue_capacity = queue_capacity;
    pool->accepting = 1;
    if (!reserve_pool_capacity(pool)) {
        pool->magic = 0u;
        pthread_cond_destroy(&pool->idle);
        pthread_cond_destroy(&pool->work_available);
        pthread_mutex_destroy(&pool->mutex);
        free(pool->workers);
        free(pool);
        return WIRESTACK_RESOLVER_OVERLOADED;
    }
    for (uint64_t index = 0u; index < worker_count; index++) {
        if (pthread_create(&pool->workers[index], NULL, resolver_worker, pool) != 0) {
            pthread_mutex_lock(&pool->mutex);
            pool->accepting = 0;
            pool->stopping = 1;
            pthread_cond_broadcast(&pool->work_available);
            pthread_mutex_unlock(&pool->mutex);
            for (uint64_t joined = 0u; joined < index; joined++) {
                pthread_join(pool->workers[joined], NULL);
            }
            release_pool_capacity(pool);
            pool->magic = 0u;
            pthread_cond_destroy(&pool->idle);
            pthread_cond_destroy(&pool->work_available);
            pthread_mutex_destroy(&pool->mutex);
            free(pool->workers);
            free(pool);
            return WIRESTACK_RESOLVER_OUT_OF_MEMORY;
        }
    }
    if (pthread_create(&pool->reaper, NULL, resolver_reaper, pool) != 0) {
        pthread_mutex_lock(&pool->mutex);
        pool->accepting = 0;
        pool->stopping = 1;
        pthread_cond_broadcast(&pool->work_available);
        pthread_mutex_unlock(&pool->mutex);
        for (uint64_t index = 0u; index < worker_count; index++) {
            pthread_join(pool->workers[index], NULL);
        }
        free_pool(pool);
        return WIRESTACK_RESOLVER_OUT_OF_MEMORY;
    }
    pthread_detach(pool->reaper);
    *out_pool_handle = (uint64_t)(uintptr_t)pool;
    return WIRESTACK_RESOLVER_OK;
}

int32_t wirestack_resolver_pool_destroy(uint64_t pool_handle) {
    struct wirestack_resolver_pool *pool =
        (struct wirestack_resolver_pool *)(uintptr_t)pool_handle;
    if (pool == NULL || pool->magic != WIRESTACK_RESOLVER_POOL_MAGIC) {
        return WIRESTACK_RESOLVER_INVALID_ARGUMENT;
    }
    pthread_mutex_lock(&pool->mutex);
    pool->accepting = 0;
    pool->stopping = 1;
    pthread_cond_broadcast(&pool->work_available);
    pthread_cond_broadcast(&pool->idle);
    pthread_mutex_unlock(&pool->mutex);
    return WIRESTACK_RESOLVER_OK;
}

int32_t wirestack_resolver_submit(
    uint64_t pool_handle,
    const char *host,
    const char *service,
    int32_t family,
    uint64_t maximum_results,
    uint64_t *out_job_handle
) {
    struct wirestack_resolver_pool *pool =
        (struct wirestack_resolver_pool *)(uintptr_t)pool_handle;
    if (pool == NULL || pool->magic != WIRESTACK_RESOLVER_POOL_MAGIC ||
        out_job_handle == NULL || host == NULL || !valid_family(family) ||
        maximum_results == 0u || maximum_results > WIRESTACK_RESOLVER_MAXIMUM_RESULTS) {
        return WIRESTACK_RESOLVER_INVALID_ARGUMENT;
    }
    *out_job_handle = 0u;
    char *host_copy = copy_bounded_string(host, WIRESTACK_RESOLVER_MAXIMUM_HOST_BYTES);
    if (host_copy == NULL) {
        return WIRESTACK_RESOLVER_INVALID_ARGUMENT;
    }
    char *service_copy = NULL;
    if (service != NULL && service[0] != '\0') {
        service_copy = copy_bounded_string(service, WIRESTACK_RESOLVER_MAXIMUM_SERVICE_BYTES);
        if (service_copy == NULL) {
            free(host_copy);
            return WIRESTACK_RESOLVER_INVALID_ARGUMENT;
        }
    }
    struct wirestack_resolver_job *job =
        (struct wirestack_resolver_job *)calloc(1u, sizeof(*job));
    if (job == NULL) {
        free(service_copy);
        free(host_copy);
        return WIRESTACK_RESOLVER_OUT_OF_MEMORY;
    }
    job->addresses = (struct wirestack_resolver_address *)calloc(
        (size_t)maximum_results, sizeof(*job->addresses));
    if (job->addresses == NULL) {
        free(job);
        free(service_copy);
        free(host_copy);
        return WIRESTACK_RESOLVER_OUT_OF_MEMORY;
    }
    job->magic = WIRESTACK_RESOLVER_JOB_MAGIC;
    job->pool = pool;
    job->host = host_copy;
    job->service = service_copy;
    job->family = family;
    job->maximum_results = maximum_results;
    job->result = WIRESTACK_RESOLVER_RESULT_SYSTEM_FAILURE;
    job->state = WIRESTACK_RESOLVER_JOB_QUEUED;
    job->references = 2;

    pthread_mutex_lock(&pool->mutex);
    if (!pool->accepting) {
        pthread_mutex_unlock(&pool->mutex);
        free(job->addresses);
        free(job->service);
        free(job->host);
        free(job);
        return WIRESTACK_RESOLVER_CLOSED;
    }
    if (pool->queued_jobs >= pool->queue_capacity ||
        pool->active_jobs >= pool->worker_count + pool->queue_capacity) {
        pool->rejected_jobs++;
        pthread_mutex_unlock(&pool->mutex);
        free(job->addresses);
        free(job->service);
        free(job->host);
        free(job);
        return WIRESTACK_RESOLVER_OVERLOADED;
    }
    if (pool->queue_tail == NULL) {
        pool->queue_head = job;
        pool->queue_tail = job;
    } else {
        pool->queue_tail->next = job;
        pool->queue_tail = job;
    }
    pool->active_jobs++;
    pool->queued_jobs++;
    pool->submitted_jobs++;
    if (pool->active_jobs > pool->peak_active_jobs) {
        pool->peak_active_jobs = pool->active_jobs;
    }
    if (pool->queued_jobs > pool->peak_queued_jobs) {
        pool->peak_queued_jobs = pool->queued_jobs;
    }
    *out_job_handle = (uint64_t)(uintptr_t)job;
    pthread_cond_signal(&pool->work_available);
    pthread_mutex_unlock(&pool->mutex);
    return WIRESTACK_RESOLVER_OK;
}

int32_t wirestack_resolver_poll(
    uint64_t job_handle,
    int32_t *out_families,
    uint8_t *out_addresses,
    uint32_t *out_scope_ids,
    uint64_t output_capacity,
    uint64_t *out_count,
    int32_t *out_result,
    int64_t *out_native_code
) {
    struct wirestack_resolver_job *job =
        (struct wirestack_resolver_job *)(uintptr_t)job_handle;
    if (job == NULL || job->magic != WIRESTACK_RESOLVER_JOB_MAGIC ||
        out_count == NULL || out_result == NULL || out_native_code == NULL) {
        return WIRESTACK_RESOLVER_INVALID_ARGUMENT;
    }
    struct wirestack_resolver_pool *pool = job->pool;
    pthread_mutex_lock(&pool->mutex);
    if (job->state != WIRESTACK_RESOLVER_JOB_COMPLETE) {
        pthread_mutex_unlock(&pool->mutex);
        return WIRESTACK_RESOLVER_PENDING;
    }
    *out_count = job->result_count;
    *out_result = job->result;
    *out_native_code = job->native_code;
    if (job->result == WIRESTACK_RESOLVER_RESULT_SUCCESS) {
        if (output_capacity < job->result_count || out_families == NULL ||
            out_addresses == NULL || out_scope_ids == NULL) {
            pthread_mutex_unlock(&pool->mutex);
            return WIRESTACK_RESOLVER_OUTPUT_TOO_SMALL;
        }
        for (uint64_t index = 0u; index < job->result_count; index++) {
            out_families[index] = job->addresses[index].family;
            out_scope_ids[index] = job->addresses[index].scope_id;
            memcpy(out_addresses + index * WIRESTACK_RESOLVER_ADDRESS_BYTES,
                   job->addresses[index].bytes,
                   WIRESTACK_RESOLVER_ADDRESS_BYTES);
        }
    }
    pthread_mutex_unlock(&pool->mutex);
    return WIRESTACK_RESOLVER_OK;
}

void wirestack_resolver_job_release(uint64_t job_handle) {
    struct wirestack_resolver_job *job =
        (struct wirestack_resolver_job *)(uintptr_t)job_handle;
    if (job == NULL || job->magic != WIRESTACK_RESOLVER_JOB_MAGIC) {
        return;
    }
    struct wirestack_resolver_pool *pool = job->pool;
    pthread_mutex_lock(&pool->mutex);
    if (!job->caller_released) {
        job->caller_released = 1;
        release_reference_locked(job);
    }
    pthread_mutex_unlock(&pool->mutex);
}

int32_t wirestack_resolver_pool_metrics(
    uint64_t pool_handle,
    uint64_t *output,
    uint64_t output_capacity
) {
    struct wirestack_resolver_pool *pool =
        (struct wirestack_resolver_pool *)(uintptr_t)pool_handle;
    if (pool == NULL || pool->magic != WIRESTACK_RESOLVER_POOL_MAGIC ||
        output == NULL || output_capacity < WIRESTACK_RESOLVER_METRIC_COUNT) {
        return WIRESTACK_RESOLVER_INVALID_ARGUMENT;
    }
    pthread_mutex_lock(&pool->mutex);
    output[WIRESTACK_RESOLVER_METRIC_WORKERS] = pool->worker_count;
    output[WIRESTACK_RESOLVER_METRIC_QUEUE_CAPACITY] = pool->queue_capacity;
    output[WIRESTACK_RESOLVER_METRIC_ACTIVE] = pool->active_jobs;
    output[WIRESTACK_RESOLVER_METRIC_QUEUED] = pool->queued_jobs;
    output[WIRESTACK_RESOLVER_METRIC_RUNNING] = pool->running_jobs;
    output[WIRESTACK_RESOLVER_METRIC_PEAK_ACTIVE] = pool->peak_active_jobs;
    output[WIRESTACK_RESOLVER_METRIC_PEAK_QUEUED] = pool->peak_queued_jobs;
    output[WIRESTACK_RESOLVER_METRIC_SUBMITTED] = pool->submitted_jobs;
    output[WIRESTACK_RESOLVER_METRIC_COMPLETED] = pool->completed_jobs;
    output[WIRESTACK_RESOLVER_METRIC_REJECTED] = pool->rejected_jobs;
    pthread_mutex_unlock(&pool->mutex);
    return WIRESTACK_RESOLVER_OK;
}
