#ifndef WIRESTACK_RESOLVER_H
#define WIRESTACK_RESOLVER_H

#include <stdint.h>

#if defined(__cplusplus)
extern "C" {
#endif

enum wirestack_resolver_status {
    WIRESTACK_RESOLVER_OK = 0,
    WIRESTACK_RESOLVER_INVALID_ARGUMENT = 1,
    WIRESTACK_RESOLVER_OUT_OF_MEMORY = 2,
    WIRESTACK_RESOLVER_CLOSED = 3,
    WIRESTACK_RESOLVER_OVERLOADED = 4,
    WIRESTACK_RESOLVER_PENDING = 5,
    WIRESTACK_RESOLVER_OUTPUT_TOO_SMALL = 6
};

enum wirestack_resolver_result {
    WIRESTACK_RESOLVER_RESULT_SUCCESS = 0,
    WIRESTACK_RESOLVER_RESULT_NAME_NOT_FOUND = 1,
    WIRESTACK_RESOLVER_RESULT_NO_DATA = 2,
    WIRESTACK_RESOLVER_RESULT_TEMPORARY_FAILURE = 3,
    WIRESTACK_RESOLVER_RESULT_INVALID_NAME = 4,
    WIRESTACK_RESOLVER_RESULT_UNSUPPORTED_FAMILY = 5,
    WIRESTACK_RESOLVER_RESULT_SYSTEM_FAILURE = 6
};

enum wirestack_resolver_family {
    WIRESTACK_RESOLVER_FAMILY_ANY = 0,
    WIRESTACK_RESOLVER_FAMILY_IPV4 = 4,
    WIRESTACK_RESOLVER_FAMILY_IPV6 = 6
};

enum wirestack_resolver_metric {
    WIRESTACK_RESOLVER_METRIC_WORKERS = 0,
    WIRESTACK_RESOLVER_METRIC_QUEUE_CAPACITY = 1,
    WIRESTACK_RESOLVER_METRIC_ACTIVE = 2,
    WIRESTACK_RESOLVER_METRIC_QUEUED = 3,
    WIRESTACK_RESOLVER_METRIC_RUNNING = 4,
    WIRESTACK_RESOLVER_METRIC_PEAK_ACTIVE = 5,
    WIRESTACK_RESOLVER_METRIC_PEAK_QUEUED = 6,
    WIRESTACK_RESOLVER_METRIC_SUBMITTED = 7,
    WIRESTACK_RESOLVER_METRIC_COMPLETED = 8,
    WIRESTACK_RESOLVER_METRIC_REJECTED = 9,
    WIRESTACK_RESOLVER_METRIC_COUNT = 10
};

int32_t wirestack_resolver_pool_create(
    uint64_t worker_count,
    uint64_t queue_capacity,
    uint64_t *out_pool_handle
);

int32_t wirestack_resolver_pool_destroy(uint64_t pool_handle);

int32_t wirestack_resolver_submit(
    uint64_t pool_handle,
    const char *host,
    const char *service,
    int32_t family,
    uint64_t maximum_results,
    uint64_t *out_job_handle
);

int32_t wirestack_resolver_poll(
    uint64_t job_handle,
    int32_t *out_families,
    uint8_t *out_addresses,
    uint64_t output_capacity,
    uint64_t *out_count,
    int32_t *out_result,
    int64_t *out_native_code
);

void wirestack_resolver_job_release(uint64_t job_handle);

int32_t wirestack_resolver_pool_metrics(
    uint64_t pool_handle,
    uint64_t *output,
    uint64_t output_capacity
);

#if defined(__cplusplus)
}
#endif

#endif
