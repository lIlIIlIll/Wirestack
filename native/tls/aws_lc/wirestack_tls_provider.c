#include "wirestack_tls_provider.h"

#include <openssl/base.h>
#include <openssl/bio.h>
#include <openssl/err.h>
#include <openssl/rand.h>
#include <openssl/ssl.h>

#include <limits.h>
#include <stdlib.h>

#if !defined(OPENSSL_IS_AWSLC)
#error "Wirestack's Linux provider must be compiled against pinned AWS-LC headers"
#endif

#define WIRESTACK_TLS_PROVIDER_MAGIC UINT64_C(0x5753544c53505231)
#define WIRESTACK_TLS_ENGINE_MAGIC UINT64_C(0x5753544c53454e31)

struct wirestack_tls_provider {
    uint64_t magic;
};

struct wirestack_tls_engine {
    uint64_t magic;
    SSL_CTX *context;
    SSL *ssl;
    BIO *incoming;
    BIO *outgoing;
};

static struct wirestack_tls_provider *provider_from_handle(uint64_t handle) {
    struct wirestack_tls_provider *provider =
        (struct wirestack_tls_provider *)(uintptr_t)handle;
    if (provider == NULL || provider->magic != WIRESTACK_TLS_PROVIDER_MAGIC) {
        return NULL;
    }
    return provider;
}

static struct wirestack_tls_engine *engine_from_handle(uint64_t handle) {
    struct wirestack_tls_engine *engine =
        (struct wirestack_tls_engine *)(uintptr_t)handle;
    if (engine == NULL || engine->magic != WIRESTACK_TLS_ENGINE_MAGIC) {
        return NULL;
    }
    return engine;
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

int32_t wirestack_tls_engine_create(
    uint64_t provider_handle,
    int32_t role,
    uint64_t *out_engine_handle
) {
    struct wirestack_tls_engine *engine = NULL;
    BIO *incoming = NULL;
    BIO *outgoing = NULL;
    if (provider_from_handle(provider_handle) == NULL || out_engine_handle == NULL ||
        (role != WIRESTACK_TLS_ENGINE_CLIENT && role != WIRESTACK_TLS_ENGINE_SERVER)) {
        return WIRESTACK_TLS_PROVIDER_INVALID_ARGUMENT;
    }
    *out_engine_handle = UINT64_C(0);
    engine = (struct wirestack_tls_engine *)calloc(1, sizeof(*engine));
    if (engine == NULL) {
        return WIRESTACK_TLS_PROVIDER_OUT_OF_MEMORY;
    }
    engine->context = SSL_CTX_new(TLS_method());
    engine->ssl = engine->context == NULL ? NULL : SSL_new(engine->context);
    incoming = BIO_new(BIO_s_mem());
    outgoing = BIO_new(BIO_s_mem());
    if (engine->ssl == NULL || incoming == NULL || outgoing == NULL) {
        BIO_free(incoming);
        BIO_free(outgoing);
        SSL_free(engine->ssl);
        SSL_CTX_free(engine->context);
        free(engine);
        return WIRESTACK_TLS_PROVIDER_ENGINE_FAILED;
    }
    BIO_set_mem_eof_return(incoming, -1);
    SSL_set_bio(engine->ssl, incoming, outgoing);
    engine->incoming = incoming;
    engine->outgoing = outgoing;
    if (role == WIRESTACK_TLS_ENGINE_CLIENT) {
        SSL_set_connect_state(engine->ssl);
    } else {
        SSL_set_accept_state(engine->ssl);
    }
    engine->magic = WIRESTACK_TLS_ENGINE_MAGIC;
    *out_engine_handle = (uint64_t)(uintptr_t)engine;
    return WIRESTACK_TLS_PROVIDER_OK;
}

void wirestack_tls_engine_destroy(uint64_t engine_handle) {
    struct wirestack_tls_engine *engine = engine_from_handle(engine_handle);
    if (engine == NULL) {
        return;
    }
    engine->magic = UINT64_C(0);
    SSL_free(engine->ssl);
    SSL_CTX_free(engine->context);
    free(engine);
}

int32_t wirestack_tls_engine_handshake_step(
    uint64_t engine_handle,
    int32_t *out_step
) {
    struct wirestack_tls_engine *engine = engine_from_handle(engine_handle);
    int result;
    int error;
    if (engine == NULL || out_step == NULL) {
        return WIRESTACK_TLS_PROVIDER_INVALID_ARGUMENT;
    }
    ERR_clear_error();
    result = SSL_do_handshake(engine->ssl);
    if (result == 1) {
        *out_step = WIRESTACK_TLS_ENGINE_COMPLETE;
        return WIRESTACK_TLS_PROVIDER_OK;
    }
    error = SSL_get_error(engine->ssl, result);
    if (error == SSL_ERROR_WANT_READ) {
        *out_step = WIRESTACK_TLS_ENGINE_WANT_READ;
        return WIRESTACK_TLS_PROVIDER_OK;
    }
    if (error == SSL_ERROR_WANT_WRITE) {
        *out_step = WIRESTACK_TLS_ENGINE_WANT_WRITE;
        return WIRESTACK_TLS_PROVIDER_OK;
    }
    return WIRESTACK_TLS_PROVIDER_ENGINE_FAILED;
}

int32_t wirestack_tls_engine_pending_ciphertext(
    uint64_t engine_handle,
    uint64_t *out_size
) {
    struct wirestack_tls_engine *engine = engine_from_handle(engine_handle);
    if (engine == NULL || out_size == NULL) {
        return WIRESTACK_TLS_PROVIDER_INVALID_ARGUMENT;
    }
    *out_size = (uint64_t)BIO_ctrl_pending(engine->outgoing);
    return WIRESTACK_TLS_PROVIDER_OK;
}

int32_t wirestack_tls_engine_drain_ciphertext(
    uint64_t engine_handle,
    uint8_t *output,
    uint64_t size,
    uint64_t *out_read
) {
    struct wirestack_tls_engine *engine = engine_from_handle(engine_handle);
    int count;
    if (engine == NULL || out_read == NULL || size > (uint64_t)INT_MAX ||
        (size != UINT64_C(0) && output == NULL)) {
        return WIRESTACK_TLS_PROVIDER_INVALID_ARGUMENT;
    }
    *out_read = UINT64_C(0);
    if (size == UINT64_C(0)) {
        return WIRESTACK_TLS_PROVIDER_OK;
    }
    count = BIO_read(engine->outgoing, output, (int)size);
    if (count <= 0) {
        return WIRESTACK_TLS_PROVIDER_ENGINE_FAILED;
    }
    *out_read = (uint64_t)count;
    return WIRESTACK_TLS_PROVIDER_OK;
}

int32_t wirestack_tls_engine_feed_ciphertext(
    uint64_t engine_handle,
    const uint8_t *input,
    uint64_t size,
    uint64_t *out_written
) {
    struct wirestack_tls_engine *engine = engine_from_handle(engine_handle);
    int count;
    if (engine == NULL || out_written == NULL || size > (uint64_t)INT_MAX ||
        (size != UINT64_C(0) && input == NULL)) {
        return WIRESTACK_TLS_PROVIDER_INVALID_ARGUMENT;
    }
    *out_written = UINT64_C(0);
    if (size == UINT64_C(0)) {
        return WIRESTACK_TLS_PROVIDER_OK;
    }
    count = BIO_write(engine->incoming, input, (int)size);
    if (count <= 0) {
        return WIRESTACK_TLS_PROVIDER_ENGINE_FAILED;
    }
    *out_written = (uint64_t)count;
    return WIRESTACK_TLS_PROVIDER_OK;
}
