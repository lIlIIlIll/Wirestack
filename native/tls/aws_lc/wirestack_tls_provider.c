#include "wirestack_tls_provider.h"

#include <openssl/base.h>
#include <openssl/bio.h>
#include <openssl/err.h>
#include <openssl/mem.h>
#include <openssl/rand.h>
#include <openssl/sha.h>
#include <openssl/ssl.h>
#include <openssl/x509.h>
#include <openssl/x509v3.h>

#include <limits.h>
#include <stdlib.h>
#include <string.h>

#if !defined(OPENSSL_IS_AWSLC)
#error "Wirestack's Linux provider must be compiled against pinned AWS-LC headers"
#endif

#define WIRESTACK_TLS_PROVIDER_MAGIC UINT64_C(0x5753544c53505231)
#define WIRESTACK_TLS_ENGINE_MAGIC UINT64_C(0x5753544c53454e31)
#define WIRESTACK_TLS_MAXIMUM_PINS 32
#define WIRESTACK_TLS_PIN_LEAF UINT8_C(0)
#define WIRESTACK_TLS_PIN_ANY_CERTIFICATE UINT8_C(1)

struct wirestack_tls_provider {
    uint64_t magic;
};

struct wirestack_tls_engine {
    uint64_t magic;
    SSL_CTX *context;
    SSL *ssl;
    BIO *incoming;
    BIO *outgoing;
    uint8_t pin_digests[WIRESTACK_TLS_MAXIMUM_PINS][32];
    uint8_t pin_scopes[WIRESTACK_TLS_MAXIMUM_PINS];
    size_t pin_count;
    int matched_pin_index;
};

static int certificate_spki_sha256(const X509 *certificate, uint8_t out_digest[32]) {
    const X509_PUBKEY *public_key = X509_get_X509_PUBKEY(certificate);
    uint8_t *encoded;
    uint8_t *cursor;
    int encoded_size;
    if (public_key == NULL) {
        return 0;
    }
    encoded_size = i2d_X509_PUBKEY(public_key, NULL);
    if (encoded_size <= 0) {
        return 0;
    }
    encoded = (uint8_t *)OPENSSL_malloc((size_t)encoded_size);
    if (encoded == NULL) {
        return 0;
    }
    cursor = encoded;
    if (i2d_X509_PUBKEY(public_key, &cursor) != encoded_size ||
        SHA256(encoded, (size_t)encoded_size, out_digest) != out_digest) {
        OPENSSL_free(encoded);
        return 0;
    }
    OPENSSL_free(encoded);
    return 1;
}

static int certificate_matches_pin(
    const struct wirestack_tls_engine *engine,
    const X509 *certificate,
    int leaf,
    size_t *out_pin_index
) {
    uint8_t digest[32];
    size_t index;
    if (!certificate_spki_sha256(certificate, digest)) {
        return 0;
    }
    for (index = 0; index < engine->pin_count; index++) {
        if (!leaf && engine->pin_scopes[index] == WIRESTACK_TLS_PIN_LEAF) {
            continue;
        }
        if (CRYPTO_memcmp(digest, engine->pin_digests[index], sizeof(digest)) == 0) {
            *out_pin_index = index;
            return 1;
        }
    }
    return 0;
}

static int wirestack_certificate_verify_callback(
    X509_STORE_CTX *store_context,
    void *argument
) {
    struct wirestack_tls_engine *engine =
        (struct wirestack_tls_engine *)argument;
    X509 *leaf;
    X509 *matched = NULL;
    STACK_OF(X509) *untrusted;
    STACK_OF(X509) *trusted;
    size_t pin_index = 0;
    size_t index;
    int result;
    if (engine == NULL || engine->magic != WIRESTACK_TLS_ENGINE_MAGIC) {
        X509_STORE_CTX_set_error(store_context, X509_V_ERR_APPLICATION_VERIFICATION);
        return 0;
    }
    if (engine->pin_count == 0) {
        return X509_verify_cert(store_context);
    }
    leaf = X509_STORE_CTX_get0_cert(store_context);
    if (leaf != NULL && certificate_matches_pin(engine, leaf, 1, &pin_index)) {
        matched = leaf;
    }
    untrusted = X509_STORE_CTX_get0_untrusted(store_context);
    if (matched == NULL && untrusted != NULL) {
        for (index = 0; index < sk_X509_num(untrusted); index++) {
            X509 *candidate = sk_X509_value(untrusted, index);
            if (candidate != leaf &&
                certificate_matches_pin(engine, candidate, 0, &pin_index)) {
                matched = candidate;
                break;
            }
        }
    }
    if (matched == NULL) {
        X509_STORE_CTX_set_error(store_context, X509_V_ERR_APPLICATION_VERIFICATION);
        return 0;
    }
    trusted = sk_X509_new_null();
    if (trusted == NULL || !sk_X509_push(trusted, matched)) {
        sk_X509_free(trusted);
        X509_STORE_CTX_set_error(store_context, X509_V_ERR_OUT_OF_MEM);
        return 0;
    }
    X509_STORE_CTX_set0_trusted_stack(store_context, trusted);
    result = X509_verify_cert(store_context);
    sk_X509_free(trusted);
    if (result == 1) {
        engine->matched_pin_index = (int)pin_index;
    }
    return result;
}

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

int32_t wirestack_tls_sha256(
    const uint8_t *input,
    uint64_t size,
    uint8_t out_digest[32]
) {
    if (out_digest == NULL || size > (uint64_t)SIZE_MAX ||
        (size != UINT64_C(0) && input == NULL)) {
        return WIRESTACK_TLS_PROVIDER_INVALID_ARGUMENT;
    }
    return SHA256(input, (size_t)size, out_digest) == out_digest
        ? WIRESTACK_TLS_PROVIDER_OK
        : WIRESTACK_TLS_PROVIDER_ENGINE_FAILED;
}

int32_t wirestack_tls_certificate_validate_der(
    const uint8_t *input,
    uint64_t size,
    uint64_t maximum_extensions,
    uint64_t *out_extension_count
) {
    const uint8_t *cursor = input;
    X509 *certificate;
    int extension_count;
    if (input == NULL || size == UINT64_C(0) || size > (uint64_t)LONG_MAX ||
        maximum_extensions > (uint64_t)INT_MAX || out_extension_count == NULL) {
        return WIRESTACK_TLS_PROVIDER_INVALID_ARGUMENT;
    }
    *out_extension_count = UINT64_C(0);
    ERR_clear_error();
    certificate = d2i_X509(NULL, &cursor, (long)size);
    if (certificate == NULL || cursor != input + size) {
        X509_free(certificate);
        return WIRESTACK_TLS_PROVIDER_CERTIFICATE_INVALID;
    }
    extension_count = X509_get_ext_count(certificate);
    X509_free(certificate);
    if (extension_count < 0) {
        return WIRESTACK_TLS_PROVIDER_CERTIFICATE_INVALID;
    }
    if ((uint64_t)extension_count > maximum_extensions) {
        return WIRESTACK_TLS_PROVIDER_LIMIT_EXCEEDED;
    }
    *out_extension_count = (uint64_t)extension_count;
    return WIRESTACK_TLS_PROVIDER_OK;
}

int32_t wirestack_tls_certificate_subject_alt_names(
    const uint8_t *input,
    uint64_t size,
    uint8_t *output,
    uint64_t output_capacity,
    uint64_t *out_required_size,
    uint64_t *out_dns_count,
    uint64_t *out_ip_count
) {
    const uint8_t *cursor = input;
    X509 *certificate = NULL;
    GENERAL_NAMES *names = NULL;
    uint64_t required = UINT64_C(0);
    uint64_t dns_count = UINT64_C(0);
    uint64_t ip_count = UINT64_C(0);
    int san_critical = -1;
    int count;
    int index;
    if (input == NULL || size == UINT64_C(0) || size > (uint64_t)LONG_MAX ||
        out_required_size == NULL || out_dns_count == NULL || out_ip_count == NULL ||
        (output_capacity != UINT64_C(0) && output == NULL)) {
        return WIRESTACK_TLS_PROVIDER_INVALID_ARGUMENT;
    }
    *out_required_size = UINT64_C(0);
    *out_dns_count = UINT64_C(0);
    *out_ip_count = UINT64_C(0);
    certificate = d2i_X509(NULL, &cursor, (long)size);
    if (certificate == NULL || cursor != input + size) {
        X509_free(certificate);
        return WIRESTACK_TLS_PROVIDER_CERTIFICATE_INVALID;
    }
    names = (GENERAL_NAMES *)X509_get_ext_d2i(
        certificate,
        NID_subject_alt_name,
        &san_critical,
        NULL
    );
    if (names == NULL) {
        X509_free(certificate);
        return san_critical == -1
            ? WIRESTACK_TLS_PROVIDER_OK
            : WIRESTACK_TLS_PROVIDER_CERTIFICATE_INVALID;
    }
    count = sk_GENERAL_NAME_num(names);
    if (count < 0 || count > 256) {
        GENERAL_NAMES_free(names);
        X509_free(certificate);
        return WIRESTACK_TLS_PROVIDER_LIMIT_EXCEEDED;
    }
    for (index = 0; index < count; index++) {
        const GENERAL_NAME *name = sk_GENERAL_NAME_value(names, index);
        const ASN1_STRING *value;
        int value_type;
        int length;
        uint8_t encoded_type;
        value = (const ASN1_STRING *)GENERAL_NAME_get0_value(name, &value_type);
        if (value_type != GEN_DNS && value_type != GEN_IPADD) {
            continue;
        }
        if (value == NULL) {
            GENERAL_NAMES_free(names);
            X509_free(certificate);
            return WIRESTACK_TLS_PROVIDER_CERTIFICATE_INVALID;
        }
        length = ASN1_STRING_length(value);
        if (length <= 0 || length > 65535 ||
            (value_type == GEN_IPADD && length != 4 && length != 16) ||
            required > UINT64_MAX - UINT64_C(3) - (uint64_t)length) {
            GENERAL_NAMES_free(names);
            X509_free(certificate);
            return WIRESTACK_TLS_PROVIDER_CERTIFICATE_INVALID;
        }
        encoded_type = value_type == GEN_DNS ? UINT8_C(1) : UINT8_C(2);
        if (output != NULL && required + UINT64_C(3) + (uint64_t)length <= output_capacity) {
            const uint8_t *data = ASN1_STRING_get0_data(value);
            output[required] = encoded_type;
            output[required + UINT64_C(1)] = (uint8_t)((unsigned)length >> 8);
            output[required + UINT64_C(2)] = (uint8_t)((unsigned)length & 0xffu);
            memcpy(output + required + UINT64_C(3), data, (size_t)length);
        }
        required += UINT64_C(3) + (uint64_t)length;
        if (value_type == GEN_DNS) {
            dns_count++;
        } else {
            ip_count++;
        }
    }
    GENERAL_NAMES_free(names);
    X509_free(certificate);
    *out_required_size = required;
    *out_dns_count = dns_count;
    *out_ip_count = ip_count;
    if (output != NULL && output_capacity < required) {
        return WIRESTACK_TLS_PROVIDER_LIMIT_EXCEEDED;
    }
    return WIRESTACK_TLS_PROVIDER_OK;
}

int32_t wirestack_tls_engine_create(
    uint64_t provider_handle,
    int32_t role,
    int32_t minimum_tls_version,
    int32_t maximum_tls_version,
    uint64_t *out_engine_handle
) {
    struct wirestack_tls_engine *engine = NULL;
    BIO *incoming = NULL;
    BIO *outgoing = NULL;
    int minimum_version;
    int maximum_version;
    if (provider_from_handle(provider_handle) == NULL || out_engine_handle == NULL ||
        (role != WIRESTACK_TLS_ENGINE_CLIENT && role != WIRESTACK_TLS_ENGINE_SERVER) ||
        (minimum_tls_version != 12 && minimum_tls_version != 13) ||
        (maximum_tls_version != 12 && maximum_tls_version != 13) ||
        minimum_tls_version > maximum_tls_version) {
        return WIRESTACK_TLS_PROVIDER_INVALID_ARGUMENT;
    }
    minimum_version = minimum_tls_version == 12 ? TLS1_2_VERSION : TLS1_3_VERSION;
    maximum_version = maximum_tls_version == 12 ? TLS1_2_VERSION : TLS1_3_VERSION;
    *out_engine_handle = UINT64_C(0);
    engine = (struct wirestack_tls_engine *)calloc(1, sizeof(*engine));
    if (engine == NULL) {
        return WIRESTACK_TLS_PROVIDER_OUT_OF_MEMORY;
    }
    engine->context = SSL_CTX_new(TLS_method());
    if (engine->context == NULL ||
        !SSL_CTX_set_min_proto_version(engine->context, minimum_version) ||
        !SSL_CTX_set_max_proto_version(engine->context, maximum_version)) {
        SSL_CTX_free(engine->context);
        free(engine);
        return WIRESTACK_TLS_PROVIDER_ENGINE_FAILED;
    }
    engine->magic = WIRESTACK_TLS_ENGINE_MAGIC;
    engine->matched_pin_index = -1;
    SSL_CTX_set_cert_verify_callback(
        engine->context,
        wirestack_certificate_verify_callback,
        engine
    );
    engine->ssl = SSL_new(engine->context);
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

int32_t wirestack_tls_engine_add_trust_anchor_der(
    uint64_t engine_handle,
    const uint8_t *input,
    uint64_t size
) {
    struct wirestack_tls_engine *engine = engine_from_handle(engine_handle);
    const uint8_t *cursor = input;
    X509 *certificate;
    int result;
    if (engine == NULL || input == NULL || size == UINT64_C(0) ||
        size > (uint64_t)LONG_MAX) {
        return WIRESTACK_TLS_PROVIDER_INVALID_ARGUMENT;
    }
    certificate = d2i_X509(NULL, &cursor, (long)size);
    if (certificate == NULL || cursor != input + size) {
        X509_free(certificate);
        return WIRESTACK_TLS_PROVIDER_CERTIFICATE_INVALID;
    }
    ERR_clear_error();
    result = X509_STORE_add_cert(SSL_CTX_get_cert_store(engine->context), certificate);
    X509_free(certificate);
    if (result != 1) {
        return WIRESTACK_TLS_PROVIDER_ENGINE_FAILED;
    }
    return WIRESTACK_TLS_PROVIDER_OK;
}

int32_t wirestack_tls_engine_add_spki_sha256_pin(
    uint64_t engine_handle,
    const uint8_t digest[32],
    int32_t scope
) {
    struct wirestack_tls_engine *engine = engine_from_handle(engine_handle);
    if (engine == NULL || digest == NULL ||
        (scope != (int32_t)WIRESTACK_TLS_PIN_LEAF &&
         scope != (int32_t)WIRESTACK_TLS_PIN_ANY_CERTIFICATE) ||
        engine->pin_count >= WIRESTACK_TLS_MAXIMUM_PINS) {
        return WIRESTACK_TLS_PROVIDER_INVALID_ARGUMENT;
    }
    memcpy(engine->pin_digests[engine->pin_count], digest, 32u);
    engine->pin_scopes[engine->pin_count] = (uint8_t)scope;
    engine->pin_count++;
    return WIRESTACK_TLS_PROVIDER_OK;
}

int32_t wirestack_tls_engine_load_verify_locations(
    uint64_t engine_handle,
    const char *certificate_bundle,
    const char *hashed_certificate_directory
) {
    struct wirestack_tls_engine *engine = engine_from_handle(engine_handle);
    if (engine == NULL || (certificate_bundle == NULL && hashed_certificate_directory == NULL)) {
        return WIRESTACK_TLS_PROVIDER_INVALID_ARGUMENT;
    }
    ERR_clear_error();
    return SSL_CTX_load_verify_locations(
        engine->context,
        certificate_bundle,
        hashed_certificate_directory
    ) == 1 ? WIRESTACK_TLS_PROVIDER_OK : WIRESTACK_TLS_PROVIDER_ENGINE_FAILED;
}

int32_t wirestack_tls_engine_load_verify_bundle(
    uint64_t engine_handle,
    const char *certificate_bundle
) {
    return wirestack_tls_engine_load_verify_locations(
        engine_handle,
        certificate_bundle,
        NULL
    );
}

int32_t wirestack_tls_engine_load_verify_directory(
    uint64_t engine_handle,
    const char *hashed_certificate_directory
) {
    return wirestack_tls_engine_load_verify_locations(
        engine_handle,
        NULL,
        hashed_certificate_directory
    );
}

int32_t wirestack_tls_engine_set_server_name(
    uint64_t engine_handle,
    const char *server_name
) {
    struct wirestack_tls_engine *engine = engine_from_handle(engine_handle);
    if (engine == NULL || server_name == NULL || server_name[0] == '\0' ||
        strlen(server_name) > 253u) {
        return WIRESTACK_TLS_PROVIDER_INVALID_ARGUMENT;
    }
    return SSL_set_tlsext_host_name(engine->ssl, server_name) == 1
        ? WIRESTACK_TLS_PROVIDER_OK
        : WIRESTACK_TLS_PROVIDER_ENGINE_FAILED;
}

int32_t wirestack_tls_engine_set_dns_reference_identity(
    uint64_t engine_handle,
    const char *dns_name
) {
    struct wirestack_tls_engine *engine = engine_from_handle(engine_handle);
    if (engine == NULL || dns_name == NULL || dns_name[0] == '\0' ||
        strlen(dns_name) > 253u) {
        return WIRESTACK_TLS_PROVIDER_INVALID_ARGUMENT;
    }
    SSL_set_hostflags(engine->ssl, X509_CHECK_FLAG_NEVER_CHECK_SUBJECT);
    return SSL_set1_host(engine->ssl, dns_name) == 1
        ? WIRESTACK_TLS_PROVIDER_OK
        : WIRESTACK_TLS_PROVIDER_ENGINE_FAILED;
}

int32_t wirestack_tls_engine_set_ip_reference_identity(
    uint64_t engine_handle,
    const uint8_t *address,
    uint64_t size
) {
    struct wirestack_tls_engine *engine = engine_from_handle(engine_handle);
    if (engine == NULL || address == NULL || (size != UINT64_C(4) && size != UINT64_C(16))) {
        return WIRESTACK_TLS_PROVIDER_INVALID_ARGUMENT;
    }
    return X509_VERIFY_PARAM_set1_ip(
        SSL_get0_param(engine->ssl),
        address,
        (size_t)size
    ) == 1 ? WIRESTACK_TLS_PROVIDER_OK : WIRESTACK_TLS_PROVIDER_ENGINE_FAILED;
}

int32_t wirestack_tls_engine_enable_peer_verification(uint64_t engine_handle) {
    struct wirestack_tls_engine *engine = engine_from_handle(engine_handle);
    if (engine == NULL) {
        return WIRESTACK_TLS_PROVIDER_INVALID_ARGUMENT;
    }
    SSL_set_verify_depth(engine->ssl, 10);
    SSL_set_verify(engine->ssl, SSL_VERIFY_PEER, NULL);
    return WIRESTACK_TLS_PROVIDER_OK;
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

static int32_t classify_io_result(
    SSL *ssl,
    int result,
    uint64_t *out_count,
    int32_t *out_step
) {
    int error;
    if (result > 0) {
        *out_count = (uint64_t)result;
        *out_step = WIRESTACK_TLS_ENGINE_IO_COMPLETE;
        return WIRESTACK_TLS_PROVIDER_OK;
    }
    error = SSL_get_error(ssl, result);
    if (error == SSL_ERROR_WANT_READ) {
        *out_step = WIRESTACK_TLS_ENGINE_IO_WANT_READ;
        return WIRESTACK_TLS_PROVIDER_OK;
    }
    if (error == SSL_ERROR_WANT_WRITE) {
        *out_step = WIRESTACK_TLS_ENGINE_IO_WANT_WRITE;
        return WIRESTACK_TLS_PROVIDER_OK;
    }
    if (error == SSL_ERROR_ZERO_RETURN) {
        *out_step = WIRESTACK_TLS_ENGINE_IO_CLOSED;
        return WIRESTACK_TLS_PROVIDER_OK;
    }
    return WIRESTACK_TLS_PROVIDER_ENGINE_FAILED;
}

int32_t wirestack_tls_engine_read_plaintext(
    uint64_t engine_handle,
    uint8_t *output,
    uint64_t size,
    uint64_t *out_read,
    int32_t *out_step
) {
    struct wirestack_tls_engine *engine = engine_from_handle(engine_handle);
    int result;
    if (engine == NULL || output == NULL || out_read == NULL || out_step == NULL ||
        size == UINT64_C(0) || size > (uint64_t)INT_MAX) {
        return WIRESTACK_TLS_PROVIDER_INVALID_ARGUMENT;
    }
    *out_read = UINT64_C(0);
    *out_step = -1;
    ERR_clear_error();
    result = SSL_read(engine->ssl, output, (int)size);
    return classify_io_result(engine->ssl, result, out_read, out_step);
}

int32_t wirestack_tls_engine_write_plaintext(
    uint64_t engine_handle,
    const uint8_t *input,
    uint64_t size,
    uint64_t *out_written,
    int32_t *out_step
) {
    struct wirestack_tls_engine *engine = engine_from_handle(engine_handle);
    int result;
    if (engine == NULL || input == NULL || out_written == NULL || out_step == NULL ||
        size == UINT64_C(0) || size > (uint64_t)INT_MAX) {
        return WIRESTACK_TLS_PROVIDER_INVALID_ARGUMENT;
    }
    *out_written = UINT64_C(0);
    *out_step = -1;
    ERR_clear_error();
    result = SSL_write(engine->ssl, input, (int)size);
    return classify_io_result(engine->ssl, result, out_written, out_step);
}
