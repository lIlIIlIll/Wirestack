#ifndef WIRESTACK_TLS_PROVIDER_H
#define WIRESTACK_TLS_PROVIDER_H

#include <stddef.h>
#include <stdint.h>

#if defined(__cplusplus)
extern "C" {
#endif

enum wirestack_tls_provider_status {
    WIRESTACK_TLS_PROVIDER_OK = 0,
    WIRESTACK_TLS_PROVIDER_INVALID_ARGUMENT = 1,
    WIRESTACK_TLS_PROVIDER_OUT_OF_MEMORY = 2,
    WIRESTACK_TLS_PROVIDER_CLOSED = 3,
    WIRESTACK_TLS_PROVIDER_RANDOM_FAILED = 4
};

enum wirestack_tls_provider_capability {
    WIRESTACK_TLS_CAP_CUSTOM_ROOTS = UINT64_C(1) << 0,
    WIRESTACK_TLS_CAP_CLIENT_CERT = UINT64_C(1) << 1,
    WIRESTACK_TLS_CAP_SERVER = UINT64_C(1) << 2,
    WIRESTACK_TLS_CAP_TLS12 = UINT64_C(1) << 3,
    WIRESTACK_TLS_CAP_TLS13 = UINT64_C(1) << 4,
    WIRESTACK_TLS_CAP_HTTP2 = UINT64_C(1) << 5,
    WIRESTACK_TLS_CAP_EXTERNAL_SIGNER = UINT64_C(1) << 6,
    WIRESTACK_TLS_CAP_SESSION_RESUMPTION = UINT64_C(1) << 7,
    WIRESTACK_TLS_CAP_SECURE_RANDOM = UINT64_C(1) << 8
};

int32_t wirestack_tls_provider_create(uint64_t *out_handle);
void wirestack_tls_provider_destroy(uint64_t handle);
const char *wirestack_tls_provider_id(uint64_t handle);
const char *wirestack_tls_provider_version(uint64_t handle);
const char *wirestack_tls_provider_fingerprint(uint64_t handle);
const char *wirestack_tls_provider_backend(uint64_t handle);
const char *wirestack_tls_provider_patch_level(uint64_t handle);
uint64_t wirestack_tls_provider_capabilities(uint64_t handle);
int32_t wirestack_tls_provider_random(uint64_t handle, uint8_t *output, uint64_t size);

#if defined(__cplusplus)
}
#endif

#endif
