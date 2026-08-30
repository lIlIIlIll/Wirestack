#define WIN32_LEAN_AND_MEAN
#define _WIN32_WINNT 0x0602

#include "wirestack_resolver.h"

#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define WIRESTACK_RESOLVER_POOL_MAGIC UINT64_C(0x5753524553503032)
#define WIRESTACK_RESOLVER_JOB_MAGIC UINT64_C(0x57535245534a3032)
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
    SRWLOCK lock;
    CONDITION_VARIABLE work_available;
    CONDITION_VARIABLE idle;
    HANDLE *workers;
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
    int winsock_started;
};

static SRWLOCK resolver_capacity_lock = SRWLOCK_INIT;
static uint64_t resolver_live_pools = 0u;
static uint64_t resolver_live_workers = 0u;

static int reserve_pool_capacity(struct wirestack_resolver_pool *pool) {
    int reserved = 0;
    AcquireSRWLockExclusive(&resolver_capacity_lock);
    if (resolver_live_pools < WIRESTACK_RESOLVER_MAXIMUM_LIVE_POOLS &&
        pool->worker_count <= WIRESTACK_RESOLVER_MAXIMUM_LIVE_WORKERS - resolver_live_workers) {
        resolver_live_pools++;
        resolver_live_workers += pool->worker_count;
        pool->capacity_reserved = 1;
        reserved = 1;
    }
    ReleaseSRWLockExclusive(&resolver_capacity_lock);
    return reserved;
}

static void release_pool_capacity(struct wirestack_resolver_pool *pool) {
    if (!pool->capacity_reserved) {
        return;
    }
    AcquireSRWLockExclusive(&resolver_capacity_lock);
    resolver_live_pools--;
    resolver_live_workers -= pool->worker_count;
    pool->capacity_reserved = 0;
    ReleaseSRWLockExclusive(&resolver_capacity_lock);
}

static void free_pool(struct wirestack_resolver_pool *pool) {
    uint64_t index;
    release_pool_capacity(pool);
    pool->magic = 0u;
    for (index = 0u; index < pool->worker_count; index++) {
        if (pool->workers[index] != NULL) {
            CloseHandle(pool->workers[index]);
        }
    }
    if (pool->winsock_started) {
        WSACleanup();
    }
    free(pool->workers);
    free(pool);
}

static size_t bounded_length(const char *value, size_t maximum) {
    size_t length = 0u;
    while (length <= maximum && value[length] != '\0') {
        length++;
    }
    return length;
}

static char *copy_bounded_string(const char *value, uint64_t maximum) {
    size_t length;
    char *copy;
    if (value == NULL) {
        return NULL;
    }
    length = bounded_length(value, (size_t)maximum);
    if (length == 0u || length > (size_t)maximum) {
        return NULL;
    }
    copy = (char *)malloc(length + 1u);
    if (copy == NULL) {
        return NULL;
    }
    memcpy(copy, value, length + 1u);
    return copy;
}

static WCHAR *utf8_to_wide(const char *value) {
    int length;
    WCHAR *result;
    if (value == NULL || value[0] == '\0') {
        return NULL;
    }
    length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value, -1, NULL, 0);
    if (length <= 0) {
        return NULL;
    }
    result = (WCHAR *)calloc((size_t)length, sizeof(WCHAR));
    if (result == NULL) {
        return NULL;
    }
    if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value, -1, result, length) != length) {
        free(result);
        return NULL;
    }
    return result;
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

static int32_t classify_winsock_error(int code) {
    switch (code) {
        case 0:
            return WIRESTACK_RESOLVER_RESULT_SUCCESS;
        case WSAHOST_NOT_FOUND:
            return WIRESTACK_RESOLVER_RESULT_NAME_NOT_FOUND;
        case WSANO_DATA:
            return WIRESTACK_RESOLVER_RESULT_NO_DATA;
        case WSATRY_AGAIN:
            return WIRESTACK_RESOLVER_RESULT_TEMPORARY_FAILURE;
        case WSAEAFNOSUPPORT:
            return WIRESTACK_RESOLVER_RESULT_UNSUPPORTED_FAMILY;
        case WSAEINVAL:
        case WSATYPE_NOT_FOUND:
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
    WakeAllConditionVariable(&pool->idle);
}

static void release_reference_locked(struct wirestack_resolver_job *job) {
    job->references--;
    if (job->references == 0) {
        free_job_locked(job);
    }
}

#if defined(WIRESTACK_RESOLVER_TEST_FIXTURE)
static void append_fixture_address(
    struct wirestack_resolver_job *job,
    int32_t family,
    const uint8_t *bytes,
    size_t size
) {
    struct wirestack_resolver_address *destination;
    if (job->result_count >= job->maximum_results ||
        (job->family != WIRESTACK_RESOLVER_FAMILY_ANY && job->family != family)) {
        return;
    }
    destination = &job->addresses[job->result_count++];
    memset(destination, 0, sizeof(*destination));
    destination->family = family;
    memcpy(destination->bytes, bytes, size);
}

static int resolve_fixture(struct wirestack_resolver_job *job) {
    static const uint8_t ipv4[4] = {127u, 0u, 0u, 1u};
    static const uint8_t ipv6[16] = {0u, 0u, 0u, 0u, 0u, 0u, 0u, 0u,
                                     0u, 0u, 0u, 0u, 0u, 0u, 0u, 1u};
    int code = 0;
    if (strcmp(job->host, "all.m2-004.test") == 0) {
        append_fixture_address(job, WIRESTACK_RESOLVER_FAMILY_IPV6, ipv6, sizeof(ipv6));
        append_fixture_address(job, WIRESTACK_RESOLVER_FAMILY_IPV4, ipv4, sizeof(ipv4));
        append_fixture_address(job, WIRESTACK_RESOLVER_FAMILY_IPV6, ipv6, sizeof(ipv6));
    } else if (strcmp(job->host, "delay.m2-004.test") == 0) {
        Sleep(250u);
        append_fixture_address(job, WIRESTACK_RESOLVER_FAMILY_IPV4, ipv4, sizeof(ipv4));
    } else if (strcmp(job->host, "noname.m2-004.test") == 0) {
        code = WSAHOST_NOT_FOUND;
    } else if (strcmp(job->host, "nodata.m2-004.test") == 0) {
        code = WSANO_DATA;
    } else if (strcmp(job->host, "again.m2-004.test") == 0) {
        code = WSATRY_AGAIN;
    } else if (strcmp(job->host, "family.m2-004.test") == 0) {
        code = WSAEAFNOSUPPORT;
    } else if (strcmp(job->host, "system.m2-004.test") == 0) {
        code = WSAEFAULT;
    } else if (strcmp(job->host, "unknown.m2-004.test") == 0) {
        code = 123456;
    } else {
        return 0;
    }
    job->native_code = (int64_t)code;
    job->result = classify_winsock_error(code);
    if (code == 0 && job->result_count == 0u) {
        job->result = WIRESTACK_RESOLVER_RESULT_NO_DATA;
    }
    return 1;
}
#endif

static void resolve_job(struct wirestack_resolver_job *job) {
    ADDRINFOW hints;
    PADDRINFOW results = NULL;
    PADDRINFOW current;
    WCHAR *host;
    WCHAR *service;
    int status;

    job->result_count = 0u;
#if defined(WIRESTACK_RESOLVER_TEST_FIXTURE)
    if (resolve_fixture(job)) {
        return;
    }
#endif
    host = utf8_to_wide(job->host);
    service = utf8_to_wide(job->service);
    if (host == NULL || (job->service != NULL && job->service[0] != '\0' && service == NULL)) {
        free(service);
        free(host);
        job->native_code = (int64_t)WSAEINVAL;
        job->result = WIRESTACK_RESOLVER_RESULT_INVALID_NAME;
        return;
    }
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = native_family(job->family);
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_flags = AI_ADDRCONFIG;
    status = GetAddrInfoW(host, service, &hints, &results);
    job->result = classify_winsock_error(status);
    job->native_code = (int64_t)status;
    if (status == 0) {
        for (current = results;
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
                memcpy(destination->bytes, &address->sin6_addr, 16u);
                job->result_count++;
            }
        }
        if (job->result_count == 0u) {
            job->result = WIRESTACK_RESOLVER_RESULT_NO_DATA;
        }
    }
    if (results != NULL) {
        FreeAddrInfoW(results);
    }
    free(service);
    free(host);
}

static DWORD WINAPI resolver_worker(LPVOID argument) {
    struct wirestack_resolver_pool *pool = (struct wirestack_resolver_pool *)argument;
    for (;;) {
        struct wirestack_resolver_job *job;
        AcquireSRWLockExclusive(&pool->lock);
        while (pool->queue_head == NULL && !pool->stopping) {
            SleepConditionVariableSRW(&pool->work_available, &pool->lock, INFINITE, 0u);
        }
        if (pool->queue_head == NULL && pool->stopping) {
            ReleaseSRWLockExclusive(&pool->lock);
            return 0u;
        }
        job = pool->queue_head;
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
            ReleaseSRWLockExclusive(&pool->lock);
            continue;
        }
        job->state = WIRESTACK_RESOLVER_JOB_RUNNING;
        pool->running_jobs++;
        ReleaseSRWLockExclusive(&pool->lock);

        resolve_job(job);

        AcquireSRWLockExclusive(&pool->lock);
        pool->running_jobs--;
        job->state = WIRESTACK_RESOLVER_JOB_COMPLETE;
        pool->completed_jobs++;
        release_reference_locked(job);
        ReleaseSRWLockExclusive(&pool->lock);
    }
}

static DWORD WINAPI resolver_reaper(LPVOID argument) {
    struct wirestack_resolver_pool *pool = (struct wirestack_resolver_pool *)argument;
    uint64_t index;
    AcquireSRWLockExclusive(&pool->lock);
    while (!pool->stopping) {
        SleepConditionVariableSRW(&pool->idle, &pool->lock, INFINITE, 0u);
    }
    ReleaseSRWLockExclusive(&pool->lock);
    for (index = 0u; index < pool->worker_count; index++) {
        WaitForSingleObject(pool->workers[index], INFINITE);
    }
    AcquireSRWLockExclusive(&pool->lock);
    while (pool->active_jobs != 0u) {
        SleepConditionVariableSRW(&pool->idle, &pool->lock, INFINITE, 0u);
    }
    ReleaseSRWLockExclusive(&pool->lock);
    free_pool(pool);
    return 0u;
}

int32_t wirestack_resolver_pool_create(
    uint64_t worker_count,
    uint64_t queue_capacity,
    uint64_t *out_pool_handle
) {
    struct wirestack_resolver_pool *pool;
    WSADATA winsock;
    uint64_t index;
    HANDLE reaper;
    if (out_pool_handle == NULL || worker_count == 0u ||
        worker_count > WIRESTACK_RESOLVER_MAXIMUM_WORKERS || queue_capacity == 0u ||
        queue_capacity > WIRESTACK_RESOLVER_MAXIMUM_QUEUE) {
        return WIRESTACK_RESOLVER_INVALID_ARGUMENT;
    }
    *out_pool_handle = 0u;
    pool = (struct wirestack_resolver_pool *)calloc(1u, sizeof(*pool));
    if (pool == NULL) {
        return WIRESTACK_RESOLVER_OUT_OF_MEMORY;
    }
    pool->workers = (HANDLE *)calloc((size_t)worker_count, sizeof(HANDLE));
    if (pool->workers == NULL) {
        free(pool);
        return WIRESTACK_RESOLVER_OUT_OF_MEMORY;
    }
    InitializeSRWLock(&pool->lock);
    InitializeConditionVariable(&pool->work_available);
    InitializeConditionVariable(&pool->idle);
    pool->magic = WIRESTACK_RESOLVER_POOL_MAGIC;
    pool->worker_count = worker_count;
    pool->queue_capacity = queue_capacity;
    pool->accepting = 1;
    if (WSAStartup(MAKEWORD(2, 2), &winsock) != 0) {
        free(pool->workers);
        free(pool);
        return WIRESTACK_RESOLVER_OUT_OF_MEMORY;
    }
    pool->winsock_started = 1;
    if (!reserve_pool_capacity(pool)) {
        WSACleanup();
        free(pool->workers);
        free(pool);
        return WIRESTACK_RESOLVER_OVERLOADED;
    }
    for (index = 0u; index < worker_count; index++) {
        pool->workers[index] = CreateThread(NULL, 0u, resolver_worker, pool, 0u, NULL);
        if (pool->workers[index] == NULL) {
            uint64_t joined;
            AcquireSRWLockExclusive(&pool->lock);
            pool->accepting = 0;
            pool->stopping = 1;
            WakeAllConditionVariable(&pool->work_available);
            ReleaseSRWLockExclusive(&pool->lock);
            for (joined = 0u; joined < index; joined++) {
                WaitForSingleObject(pool->workers[joined], INFINITE);
            }
            free_pool(pool);
            return WIRESTACK_RESOLVER_OUT_OF_MEMORY;
        }
    }
    reaper = CreateThread(NULL, 0u, resolver_reaper, pool, 0u, NULL);
    if (reaper == NULL) {
        AcquireSRWLockExclusive(&pool->lock);
        pool->accepting = 0;
        pool->stopping = 1;
        WakeAllConditionVariable(&pool->work_available);
        ReleaseSRWLockExclusive(&pool->lock);
        for (index = 0u; index < worker_count; index++) {
            WaitForSingleObject(pool->workers[index], INFINITE);
        }
        free_pool(pool);
        return WIRESTACK_RESOLVER_OUT_OF_MEMORY;
    }
    CloseHandle(reaper);
    *out_pool_handle = (uint64_t)(uintptr_t)pool;
    return WIRESTACK_RESOLVER_OK;
}

int32_t wirestack_resolver_pool_destroy(uint64_t pool_handle) {
    struct wirestack_resolver_pool *pool =
        (struct wirestack_resolver_pool *)(uintptr_t)pool_handle;
    if (pool == NULL || pool->magic != WIRESTACK_RESOLVER_POOL_MAGIC) {
        return WIRESTACK_RESOLVER_INVALID_ARGUMENT;
    }
    AcquireSRWLockExclusive(&pool->lock);
    pool->accepting = 0;
    pool->stopping = 1;
    WakeAllConditionVariable(&pool->work_available);
    WakeAllConditionVariable(&pool->idle);
    ReleaseSRWLockExclusive(&pool->lock);
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
    struct wirestack_resolver_job *job;
    char *host_copy;
    char *service_copy = NULL;
    if (pool == NULL || pool->magic != WIRESTACK_RESOLVER_POOL_MAGIC ||
        out_job_handle == NULL || host == NULL || !valid_family(family) ||
        maximum_results == 0u || maximum_results > WIRESTACK_RESOLVER_MAXIMUM_RESULTS) {
        return WIRESTACK_RESOLVER_INVALID_ARGUMENT;
    }
    *out_job_handle = 0u;
    host_copy = copy_bounded_string(host, WIRESTACK_RESOLVER_MAXIMUM_HOST_BYTES);
    if (host_copy == NULL) {
        return WIRESTACK_RESOLVER_INVALID_ARGUMENT;
    }
    if (service != NULL && service[0] != '\0') {
        service_copy = copy_bounded_string(service, WIRESTACK_RESOLVER_MAXIMUM_SERVICE_BYTES);
        if (service_copy == NULL) {
            free(host_copy);
            return WIRESTACK_RESOLVER_INVALID_ARGUMENT;
        }
    }
    job = (struct wirestack_resolver_job *)calloc(1u, sizeof(*job));
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

    AcquireSRWLockExclusive(&pool->lock);
    if (!pool->accepting) {
        ReleaseSRWLockExclusive(&pool->lock);
        free(job->addresses);
        free(job->service);
        free(job->host);
        free(job);
        return WIRESTACK_RESOLVER_CLOSED;
    }
    if (pool->queued_jobs >= pool->queue_capacity ||
        pool->active_jobs >= pool->worker_count + pool->queue_capacity) {
        pool->rejected_jobs++;
        ReleaseSRWLockExclusive(&pool->lock);
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
    WakeConditionVariable(&pool->work_available);
    ReleaseSRWLockExclusive(&pool->lock);
    return WIRESTACK_RESOLVER_OK;
}

int32_t wirestack_resolver_poll(
    uint64_t job_handle,
    int32_t *out_families,
    uint8_t *out_addresses,
    uint64_t output_capacity,
    uint64_t *out_count,
    int32_t *out_result,
    int64_t *out_native_code
) {
    struct wirestack_resolver_job *job =
        (struct wirestack_resolver_job *)(uintptr_t)job_handle;
    struct wirestack_resolver_pool *pool;
    uint64_t index;
    if (job == NULL || job->magic != WIRESTACK_RESOLVER_JOB_MAGIC ||
        out_count == NULL || out_result == NULL || out_native_code == NULL) {
        return WIRESTACK_RESOLVER_INVALID_ARGUMENT;
    }
    pool = job->pool;
    AcquireSRWLockExclusive(&pool->lock);
    if (job->state != WIRESTACK_RESOLVER_JOB_COMPLETE) {
        ReleaseSRWLockExclusive(&pool->lock);
        return WIRESTACK_RESOLVER_PENDING;
    }
    *out_count = job->result_count;
    *out_result = job->result;
    *out_native_code = job->native_code;
    if (job->result == WIRESTACK_RESOLVER_RESULT_SUCCESS) {
        if (output_capacity < job->result_count || out_families == NULL || out_addresses == NULL) {
            ReleaseSRWLockExclusive(&pool->lock);
            return WIRESTACK_RESOLVER_OUTPUT_TOO_SMALL;
        }
        for (index = 0u; index < job->result_count; index++) {
            out_families[index] = job->addresses[index].family;
            memcpy(out_addresses + index * WIRESTACK_RESOLVER_ADDRESS_BYTES,
                   job->addresses[index].bytes, WIRESTACK_RESOLVER_ADDRESS_BYTES);
        }
    }
    ReleaseSRWLockExclusive(&pool->lock);
    return WIRESTACK_RESOLVER_OK;
}

void wirestack_resolver_job_release(uint64_t job_handle) {
    struct wirestack_resolver_job *job =
        (struct wirestack_resolver_job *)(uintptr_t)job_handle;
    struct wirestack_resolver_pool *pool;
    if (job == NULL || job->magic != WIRESTACK_RESOLVER_JOB_MAGIC) {
        return;
    }
    pool = job->pool;
    AcquireSRWLockExclusive(&pool->lock);
    if (!job->caller_released) {
        job->caller_released = 1;
        release_reference_locked(job);
    }
    ReleaseSRWLockExclusive(&pool->lock);
}

int32_t wirestack_resolver_pool_metrics(
    uint64_t pool_handle,
    uint64_t *output,
    uint64_t output_capacity
) {
    struct wirestack_resolver_pool *pool =
        (struct wirestack_resolver_pool *)(uintptr_t)pool_handle;
    if (pool == NULL || pool->magic != WIRESTACK_RESOLVER_POOL_MAGIC || output == NULL ||
        output_capacity < WIRESTACK_RESOLVER_METRIC_COUNT) {
        return WIRESTACK_RESOLVER_INVALID_ARGUMENT;
    }
    AcquireSRWLockExclusive(&pool->lock);
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
    ReleaseSRWLockExclusive(&pool->lock);
    return WIRESTACK_RESOLVER_OK;
}
