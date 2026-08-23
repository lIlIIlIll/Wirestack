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
    WIRESTACK_TLS_PROVIDER_RANDOM_FAILED = 4,
    WIRESTACK_TLS_PROVIDER_ENGINE_FAILED = 5
};

enum wirestack_tls_engine_role {
    WIRESTACK_TLS_ENGINE_CLIENT = 0,
    WIRESTACK_TLS_ENGINE_SERVER = 1
};

enum wirestack_tls_engine_step {
    WIRESTACK_TLS_ENGINE_COMPLETE = 0,
    WIRESTACK_TLS_ENGINE_WANT_READ = 1,
    WIRESTACK_TLS_ENGINE_WANT_WRITE = 2
};

enum wirestack_tls_engine_io_step {
    WIRESTACK_TLS_ENGINE_IO_COMPLETE = 0,
    WIRESTACK_TLS_ENGINE_IO_WANT_READ = 1,
    WIRESTACK_TLS_ENGINE_IO_WANT_WRITE = 2,
    WIRESTACK_TLS_ENGINE_IO_CLOSED = 3
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

int32_t wirestack_tls_engine_create(
    uint64_t provider_handle,
    int32_t role,
    int32_t minimum_tls_version,
    int32_t maximum_tls_version,
    uint64_t *out_engine_handle
);
void wirestack_tls_engine_destroy(uint64_t engine_handle);
int32_t wirestack_tls_engine_handshake_step(
    uint64_t engine_handle,
    int32_t *out_step
);
int32_t wirestack_tls_engine_pending_ciphertext(
    uint64_t engine_handle,
    uint64_t *out_size
);
int32_t wirestack_tls_engine_drain_ciphertext(
    uint64_t engine_handle,
    uint8_t *output,
    uint64_t size,
    uint64_t *out_read
);
int32_t wirestack_tls_engine_feed_ciphertext(
    uint64_t engine_handle,
    const uint8_t *input,
    uint64_t size,
    uint64_t *out_written
);
int32_t wirestack_tls_engine_read_plaintext(
    uint64_t engine_handle,
    uint8_t *output,
    uint64_t size,
    uint64_t *out_read,
    int32_t *out_step
);
int32_t wirestack_tls_engine_write_plaintext(
    uint64_t engine_handle,
    const uint8_t *input,
    uint64_t size,
    uint64_t *out_written,
    int32_t *out_step
);

#if defined(__cplusplus)
}
#endif

#endif
