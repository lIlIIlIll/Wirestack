#include "wirestack_tls_provider.h"

#include <openssl/base.h>
#include <openssl/rand.h>

#include <stdlib.h>

#if !defined(OPENSSL_IS_AWSLC)
#error "Wirestack's Linux provider must be compiled against pinned AWS-LC headers"
#endif

#define WIRESTACK_TLS_PROVIDER_MAGIC UINT64_C(0x5753544c53505231)

struct wirestack_tls_provider {
    uint64_t magic;
};

static struct wirestack_tls_provider *provider_from_handle(uint64_t handle) {
    struct wirestack_tls_provider *provider =
        (struct wirestack_tls_provider *)(uintptr_t)handle;
    if (provider == NULL || provider->magic != WIRESTACK_TLS_PROVIDER_MAGIC) {
        return NULL;
    }
    return provider;
}

int32_t wirestack_tls_provider_create(uint64_t *out_handle) {
    struct wirestack_tls_provider *provider;
    if (out_handle == NULL) {
        return WIRESTACK_TLS_PROVIDER_INVALID_ARGUMENT;
    }
    *out_handle = UINT64_C(0);
    provider = (struct wirestack_tls_provider *)calloc(1, sizeof(*provider));
    if (provider == NULL) {
        return WIRESTACK_TLS_PROVIDER_OUT_OF_MEMORY;
    }
    provider->magic = WIRESTACK_TLS_PROVIDER_MAGIC;
    *out_handle = (uint64_t)(uintptr_t)provider;
    return WIRESTACK_TLS_PROVIDER_OK;
}

void wirestack_tls_provider_destroy(uint64_t handle) {
    struct wirestack_tls_provider *provider = provider_from_handle(handle);
    if (provider == NULL) {
        return;
    }
    provider->magic = UINT64_C(0);
    free(provider);
}

const char *wirestack_tls_provider_id(uint64_t handle) {
    return provider_from_handle(handle) == NULL ? NULL : "aws-lc";
}

const char *wirestack_tls_provider_version(uint64_t handle) {
    return provider_from_handle(handle) == NULL ? NULL : "5.5.0";
}

const char *wirestack_tls_provider_fingerprint(uint64_t handle) {
    return provider_from_handle(handle) == NULL
        ? NULL
        : "0058686c2ce423c9c416c0597ae84bb30d07ee71271acf58e110f69f802f6478";
}

const char *wirestack_tls_provider_backend(uint64_t handle) {
    return provider_from_handle(handle) == NULL ? NULL : "aws-lc-static";
}

const char *wirestack_tls_provider_patch_level(uint64_t handle) {
    return provider_from_handle(handle) == NULL ? NULL : "abi-1;patches=none";
}

uint64_t wirestack_tls_provider_capabilities(uint64_t handle) {
    if (provider_from_handle(handle) == NULL) {
        return UINT64_C(0);
    }
    return WIRESTACK_TLS_CAP_CUSTOM_ROOTS |
        WIRESTACK_TLS_CAP_CLIENT_CERT |
        WIRESTACK_TLS_CAP_SERVER |
        WIRESTACK_TLS_CAP_TLS12 |
        WIRESTACK_TLS_CAP_TLS13 |
        WIRESTACK_TLS_CAP_HTTP2 |
        WIRESTACK_TLS_CAP_EXTERNAL_SIGNER |
        WIRESTACK_TLS_CAP_SESSION_RESUMPTION |
        WIRESTACK_TLS_CAP_SECURE_RANDOM;
}

int32_t wirestack_tls_provider_random(uint64_t handle, uint8_t *output, uint64_t size) {
    if (provider_from_handle(handle) == NULL) {
        return WIRESTACK_TLS_PROVIDER_CLOSED;
    }
    if (size == UINT64_C(0)) {
        return WIRESTACK_TLS_PROVIDER_OK;
    }
    if (output == NULL || size > (uint64_t)SIZE_MAX) {
        return WIRESTACK_TLS_PROVIDER_INVALID_ARGUMENT;
    }
    return RAND_bytes(output, (size_t)size) == 1
        ? WIRESTACK_TLS_PROVIDER_OK
        : WIRESTACK_TLS_PROVIDER_RANDOM_FAILED;
}
