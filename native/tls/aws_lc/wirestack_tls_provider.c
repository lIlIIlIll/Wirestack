#include "wirestack_tls_provider.h"

#include <openssl/base.h>
#include <openssl/bio.h>
#include <openssl/err.h>
#include <openssl/mem.h>
#include <openssl/pool.h>
#include <openssl/rand.h>
#include <openssl/sha.h>
#include <openssl/ssl.h>
#include <openssl/x509.h>
#include <openssl/x509v3.h>

#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#if !defined(OPENSSL_IS_AWSLC)
#error "Wirestack's Linux provider must be compiled against pinned AWS-LC headers"
#endif
#if !defined(WIRESTACK_TLS_BUILD_FINGERPRINT)
#error "Wirestack's Linux provider requires a repository build fingerprint"
#endif

#define WIRESTACK_TLS_PROVIDER_MAGIC UINT64_C(0x5753544c53505231)
#define WIRESTACK_TLS_ENGINE_MAGIC UINT64_C(0x5753544c53454e31)
#define WIRESTACK_TLS_MAXIMUM_PINS 32
#define WIRESTACK_TLS_MAXIMUM_SIGNER_INPUT (64u * 1024u)
#define WIRESTACK_TLS_MAXIMUM_SIGNATURE (16u * 1024u)
#define WIRESTACK_TLS_MAXIMUM_ALPN_WIRE_BYTES 4096u
#define WIRESTACK_TLS_MAXIMUM_PEER_CHAIN_LENGTH 16u
#define WIRESTACK_TLS_MAXIMUM_PEER_CERTIFICATE_BYTES (256u * 1024u)
#define WIRESTACK_TLS_MAXIMUM_PEER_CHAIN_BYTES (1024u * 1024u)
#define WIRESTACK_TLS_MAXIMUM_SESSION_BYTES (256u * 1024u)
#define WIRESTACK_TLS_TICKET_KEY_BYTES 48u
#define WIRESTACK_TLS_TICKET_KEY_ROTATION_SECONDS (48u * 60u * 60u)
#define WIRESTACK_TLS_PIN_LEAF UINT8_C(0)
#define WIRESTACK_TLS_PIN_ANY_CERTIFICATE UINT8_C(1)

struct wirestack_tls_provider {
    uint64_t magic;
    uint8_t ticket_key[WIRESTACK_TLS_TICKET_KEY_BYTES];
    uint64_t ticket_key_created_at;
};

enum wirestack_tls_signer_state {
    WIRESTACK_TLS_SIGNER_IDLE = 0,
    WIRESTACK_TLS_SIGNER_REQUESTED = 1,
    WIRESTACK_TLS_SIGNER_READY = 2,
    WIRESTACK_TLS_SIGNER_FAILED = 3
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
    uint8_t *signer_input;
    size_t signer_input_size;
    uint16_t signer_algorithm;
    uint8_t *signer_signature;
    size_t signer_signature_size;
    int signer_state;
    int role;
    uint8_t *server_alpn_protocols;
    size_t server_alpn_protocols_size;
    int alpn_required;
    uint8_t requested_server_name[254];
    size_t requested_server_name_size;
    int server_selection_state;
    uint8_t *pending_session;
    size_t pending_session_size;
    uint64_t pending_session_lifetime_seconds;
    int pending_session_single_use;
    int post_handshake_tickets_flushed;
    int32_t last_error_class;
    int64_t last_native_reason;
    int64_t last_verify_result;
    int32_t last_peer_alert;
};

static void clear_last_error(struct wirestack_tls_engine *engine) {
    engine->last_error_class = WIRESTACK_TLS_ERROR_PROVIDER_FAILURE;
    engine->last_native_reason = 0;
    engine->last_verify_result = X509_V_OK;
    engine->last_peer_alert = -1;
}

static int32_t classify_verify_result(long verify_result) {
    switch (verify_result) {
        case X509_V_ERR_HOSTNAME_MISMATCH:
        case X509_V_ERR_IP_ADDRESS_MISMATCH:
            return WIRESTACK_TLS_ERROR_IDENTITY_MISMATCH;
        case X509_V_ERR_CERT_HAS_EXPIRED:
            return WIRESTACK_TLS_ERROR_CERTIFICATE_EXPIRED;
        case X509_V_ERR_CERT_REVOKED:
            return WIRESTACK_TLS_ERROR_CERTIFICATE_REVOKED;
        default:
            return WIRESTACK_TLS_ERROR_CERTIFICATE_UNTRUSTED;
    }
}

static void capture_last_error(struct wirestack_tls_engine *engine) {
    uint32_t packed = ERR_peek_last_error();
    int reason = packed == 0u ? 0 : ERR_GET_REASON(packed);
    long verify_result = SSL_get_verify_result(engine->ssl);
    int32_t explicit_class = engine->last_error_class;
    clear_last_error(engine);
    engine->last_native_reason = (int64_t)reason;
    engine->last_verify_result = (int64_t)verify_result;
    if (explicit_class != WIRESTACK_TLS_ERROR_PROVIDER_FAILURE) {
        engine->last_error_class = explicit_class;
        return;
    }
    if (reason >= 1000 && reason <= 1255) {
        engine->last_peer_alert = (int32_t)(reason - 1000);
        switch (reason) {
            case SSL_R_SSLV3_ALERT_BAD_RECORD_MAC:
                engine->last_error_class = WIRESTACK_TLS_ERROR_BAD_MAC;
                return;
            case SSL_R_TLSV1_ALERT_RECORD_OVERFLOW:
            case SSL_R_TLSV1_ALERT_DECODE_ERROR:
                engine->last_error_class = WIRESTACK_TLS_ERROR_INVALID_RECORD;
                return;
            case SSL_R_TLSV1_ALERT_PROTOCOL_VERSION:
                engine->last_error_class = WIRESTACK_TLS_ERROR_UNSUPPORTED_VERSION;
                return;
            case SSL_R_TLSV1_ALERT_NO_APPLICATION_PROTOCOL:
                engine->last_error_class = WIRESTACK_TLS_ERROR_NO_SHARED_ALPN;
                return;
            case SSL_R_TLSV1_ALERT_CERTIFICATE_REQUIRED:
            case SSL_R_SSLV3_ALERT_NO_CERTIFICATE:
                engine->last_error_class = WIRESTACK_TLS_ERROR_CLIENT_CERTIFICATE_REQUIRED;
                return;
            case SSL_R_SSLV3_ALERT_CERTIFICATE_REVOKED:
                engine->last_error_class = WIRESTACK_TLS_ERROR_CERTIFICATE_REVOKED;
                return;
            case SSL_R_SSLV3_ALERT_CERTIFICATE_EXPIRED:
                engine->last_error_class = WIRESTACK_TLS_ERROR_CERTIFICATE_EXPIRED;
                return;
            case SSL_R_TLSV1_ALERT_UNKNOWN_CA:
            case SSL_R_SSLV3_ALERT_BAD_CERTIFICATE:
            case SSL_R_SSLV3_ALERT_UNSUPPORTED_CERTIFICATE:
            case SSL_R_SSLV3_ALERT_CERTIFICATE_UNKNOWN:
                engine->last_error_class = WIRESTACK_TLS_ERROR_CERTIFICATE_UNTRUSTED;
                return;
            default:
                engine->last_error_class = WIRESTACK_TLS_ERROR_PEER_ALERT;
                return;
        }
    }
    if (reason == SSL_R_PEER_DID_NOT_RETURN_A_CERTIFICATE) {
        engine->last_error_class = WIRESTACK_TLS_ERROR_CLIENT_CERTIFICATE_REQUIRED;
    } else if (reason == SSL_R_CERTIFICATE_VERIFY_FAILED || verify_result != X509_V_OK) {
        engine->last_error_class = classify_verify_result(verify_result);
    } else if (reason == SSL_R_NO_SHARED_CIPHER) {
        engine->last_error_class = WIRESTACK_TLS_ERROR_NO_SHARED_CIPHER;
    } else if (reason == SSL_R_NO_APPLICATION_PROTOCOL) {
        engine->last_error_class = WIRESTACK_TLS_ERROR_NO_SHARED_ALPN;
    } else if (reason == SSL_R_UNSUPPORTED_PROTOCOL ||
        reason == SSL_R_WRONG_VERSION_NUMBER || reason == SSL_R_UNKNOWN_PROTOCOL) {
        engine->last_error_class = WIRESTACK_TLS_ERROR_UNSUPPORTED_VERSION;
    } else if (reason == SSL_R_DECRYPTION_FAILED_OR_BAD_RECORD_MAC) {
        engine->last_error_class = WIRESTACK_TLS_ERROR_BAD_MAC;
    } else if (reason == SSL_R_INVALID_SSL_SESSION) {
        engine->last_error_class = WIRESTACK_TLS_ERROR_SESSION_FAILURE;
    } else if (engine->signer_state == WIRESTACK_TLS_SIGNER_FAILED) {
        engine->last_error_class = WIRESTACK_TLS_ERROR_PRIVATE_KEY_FAILURE;
    } else if (reason != 0) {
        engine->last_error_class = WIRESTACK_TLS_ERROR_PROTOCOL_VIOLATION;
    }
}

enum wirestack_tls_server_selection_state {
    WIRESTACK_TLS_SERVER_SELECTION_DISABLED = 0,
    WIRESTACK_TLS_SERVER_SELECTION_IDLE = 1,
    WIRESTACK_TLS_SERVER_SELECTION_REQUESTED = 2,
    WIRESTACK_TLS_SERVER_SELECTION_READY = 3,
    WIRESTACK_TLS_SERVER_SELECTION_FAILED = 4,
    WIRESTACK_TLS_SERVER_SELECTION_COMPLETE = 5
};

static void clear_sensitive_buffer(uint8_t **buffer, size_t *size) {
    if (*buffer != NULL) {
        OPENSSL_cleanse(*buffer, *size);
        free(*buffer);
        *buffer = NULL;
    }
    *size = 0;
}

static int wirestack_new_session(SSL *ssl, SSL_SESSION *session) {
    struct wirestack_tls_engine *engine =
        (struct wirestack_tls_engine *)SSL_get_app_data(ssl);
    uint8_t *serialized = NULL;
    size_t serialized_size = 0u;
    if (engine == NULL || engine->magic != WIRESTACK_TLS_ENGINE_MAGIC ||
        engine->role != WIRESTACK_TLS_ENGINE_CLIENT ||
        SSL_SESSION_is_resumable(session) != 1 ||
        SSL_SESSION_to_bytes(session, &serialized, &serialized_size) != 1) {
        return 0;
    }
    if (serialized_size == 0u || serialized_size > WIRESTACK_TLS_MAXIMUM_SESSION_BYTES) {
        if (serialized != NULL) {
            OPENSSL_cleanse(serialized, serialized_size);
            OPENSSL_free(serialized);
        }
        return 0;
    }
    clear_sensitive_buffer(&engine->pending_session, &engine->pending_session_size);
    engine->pending_session = (uint8_t *)malloc(serialized_size);
    if (engine->pending_session != NULL) {
        memcpy(engine->pending_session, serialized, serialized_size);
        engine->pending_session_size = serialized_size;
        engine->pending_session_lifetime_seconds =
            (uint64_t)SSL_SESSION_get_timeout(session);
        engine->pending_session_single_use =
            SSL_SESSION_should_be_single_use(session) != 0 ? 1 : 0;
    }
    OPENSSL_cleanse(serialized, serialized_size);
    OPENSSL_free(serialized);
    return 0;
}

static enum ssl_private_key_result_t wirestack_external_sign(
    SSL *ssl,
    uint8_t *out,
    size_t *out_len,
    size_t max_out,
    uint16_t signature_algorithm,
    const uint8_t *input,
    size_t input_size
) {
    struct wirestack_tls_engine *engine =
        (struct wirestack_tls_engine *)SSL_get_app_data(ssl);
    (void)out;
    (void)out_len;
    (void)max_out;
    if (engine == NULL || engine->magic != WIRESTACK_TLS_ENGINE_MAGIC ||
        engine->signer_state != WIRESTACK_TLS_SIGNER_IDLE || input == NULL ||
        input_size == 0 || input_size > WIRESTACK_TLS_MAXIMUM_SIGNER_INPUT) {
        return ssl_private_key_failure;
    }
    engine->signer_input = (uint8_t *)malloc(input_size);
    if (engine->signer_input == NULL) {
        return ssl_private_key_failure;
    }
    memcpy(engine->signer_input, input, input_size);
    engine->signer_input_size = input_size;
    engine->signer_algorithm = signature_algorithm;
    engine->signer_state = WIRESTACK_TLS_SIGNER_REQUESTED;
    return ssl_private_key_retry;
}

static enum ssl_private_key_result_t wirestack_external_sign_complete(
    SSL *ssl,
    uint8_t *out,
    size_t *out_len,
    size_t max_out
) {
    struct wirestack_tls_engine *engine =
        (struct wirestack_tls_engine *)SSL_get_app_data(ssl);
    if (engine == NULL || engine->magic != WIRESTACK_TLS_ENGINE_MAGIC) {
        return ssl_private_key_failure;
    }
    if (engine->signer_state == WIRESTACK_TLS_SIGNER_REQUESTED) {
        return ssl_private_key_retry;
    }
    if (engine->signer_state == WIRESTACK_TLS_SIGNER_FAILED) {
        clear_sensitive_buffer(&engine->signer_input, &engine->signer_input_size);
        engine->last_error_class = WIRESTACK_TLS_ERROR_PRIVATE_KEY_FAILURE;
        engine->signer_state = WIRESTACK_TLS_SIGNER_IDLE;
        return ssl_private_key_failure;
    }
    if (engine->signer_state != WIRESTACK_TLS_SIGNER_READY ||
        engine->signer_signature == NULL || engine->signer_signature_size == 0 ||
        engine->signer_signature_size > max_out) {
        return ssl_private_key_failure;
    }
    memcpy(out, engine->signer_signature, engine->signer_signature_size);
    *out_len = engine->signer_signature_size;
    clear_sensitive_buffer(&engine->signer_input, &engine->signer_input_size);
    clear_sensitive_buffer(&engine->signer_signature, &engine->signer_signature_size);
    engine->signer_state = WIRESTACK_TLS_SIGNER_IDLE;
    return ssl_private_key_success;
}

static const SSL_PRIVATE_KEY_METHOD WIRESTACK_EXTERNAL_KEY_METHOD = {
    wirestack_external_sign,
    NULL,
    wirestack_external_sign_complete
};

static int wirestack_alpn_select(
    SSL *ssl,
    const uint8_t **out,
    uint8_t *out_len,
    const uint8_t *in,
    unsigned in_len,
    void *arg
) {
    struct wirestack_tls_engine *engine = (struct wirestack_tls_engine *)arg;
    size_t server_offset = 0;
    (void)ssl;
    if (engine == NULL || engine->magic != WIRESTACK_TLS_ENGINE_MAGIC ||
        engine->server_alpn_protocols == NULL ||
        engine->server_alpn_protocols_size == 0u) {
        return SSL_TLSEXT_ERR_ALERT_FATAL;
    }
    while (server_offset < engine->server_alpn_protocols_size) {
        size_t server_length = engine->server_alpn_protocols[server_offset];
        size_t client_offset = 0;
        const uint8_t *server_value =
            engine->server_alpn_protocols + server_offset + 1u;
        server_offset += 1u + server_length;
        while (client_offset < (size_t)in_len) {
            size_t client_length = in[client_offset];
            if (client_length == 0u ||
                client_length > (size_t)in_len - client_offset - 1u) {
                return SSL_TLSEXT_ERR_ALERT_FATAL;
            }
            const uint8_t *client_value = in + client_offset + 1u;
            if (client_length == server_length &&
                memcmp(client_value, server_value, server_length) == 0) {
                *out = client_value;
                *out_len = (uint8_t)client_length;
                return SSL_TLSEXT_ERR_OK;
            }
            client_offset += 1u + client_length;
        }
    }
    engine->last_error_class = WIRESTACK_TLS_ERROR_NO_SHARED_ALPN;
    return SSL_TLSEXT_ERR_ALERT_FATAL;
}

static int valid_alpn_wire_list(const uint8_t *protocols, size_t size) {
    size_t offset = 0;
    if (protocols == NULL || size == 0u || size > WIRESTACK_TLS_MAXIMUM_ALPN_WIRE_BYTES) {
        return 0;
    }
    while (offset < size) {
        size_t length = protocols[offset];
        if (length == 0u || length > size - offset - 1u) {
            return 0;
        }
        offset += 1u + length;
    }
    return offset == size;
}

static enum ssl_select_cert_result_t wirestack_select_server_certificate(
    const SSL_CLIENT_HELLO *client_hello
) {
    struct wirestack_tls_engine *engine;
    const char *server_name;
    size_t size;
    if (client_hello == NULL || client_hello->ssl == NULL) {
        return ssl_select_cert_error;
    }
    engine = (struct wirestack_tls_engine *)SSL_get_app_data(client_hello->ssl);
    if (engine == NULL || engine->magic != WIRESTACK_TLS_ENGINE_MAGIC) {
        return ssl_select_cert_error;
    }
    if (engine->server_selection_state == WIRESTACK_TLS_SERVER_SELECTION_READY) {
        engine->server_selection_state = WIRESTACK_TLS_SERVER_SELECTION_COMPLETE;
        return ssl_select_cert_success;
    }
    if (engine->server_selection_state == WIRESTACK_TLS_SERVER_SELECTION_FAILED) {
        engine->server_selection_state = WIRESTACK_TLS_SERVER_SELECTION_COMPLETE;
        return ssl_select_cert_error;
    }
    if (engine->server_selection_state == WIRESTACK_TLS_SERVER_SELECTION_REQUESTED) {
        return ssl_select_cert_retry;
    }
    if (engine->server_selection_state != WIRESTACK_TLS_SERVER_SELECTION_IDLE) {
        return ssl_select_cert_error;
    }
    server_name = SSL_get_servername(client_hello->ssl, TLSEXT_NAMETYPE_host_name);
    size = server_name == NULL ? 0u : strlen(server_name);
    if (size > 253u) {
        return ssl_select_cert_error;
    }
    if (size != 0u) {
        memcpy(engine->requested_server_name, server_name, size);
    }
    engine->requested_server_name_size = size;
    engine->server_selection_state = WIRESTACK_TLS_SERVER_SELECTION_REQUESTED;
    return ssl_select_cert_retry;
}

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

static X509 *parse_exact_x509(const uint8_t *input, uint64_t size) {
    const uint8_t *cursor = input;
    X509 *certificate;
    if (input == NULL || size == UINT64_C(0) || size > (uint64_t)LONG_MAX) {
        return NULL;
    }
    certificate = d2i_X509(NULL, &cursor, (long)size);
    if (certificate == NULL || cursor != input + size) {
        X509_free(certificate);
        return NULL;
    }
    return certificate;
}

static EVP_PKEY *parse_exact_pkcs8(const uint8_t *input, uint64_t size) {
    const uint8_t *cursor = input;
    PKCS8_PRIV_KEY_INFO *private_key_info;
    EVP_PKEY *private_key;
    if (input == NULL || size == UINT64_C(0) || size > (uint64_t)LONG_MAX) {
        return NULL;
    }
    private_key_info = d2i_PKCS8_PRIV_KEY_INFO(NULL, &cursor, (long)size);
    if (private_key_info == NULL || cursor != input + size) {
        PKCS8_PRIV_KEY_INFO_free(private_key_info);
        return NULL;
    }
    private_key = EVP_PKCS82PKEY(private_key_info);
    PKCS8_PRIV_KEY_INFO_free(private_key_info);
    return private_key;
}

static EVP_PKEY *parse_exact_spki(const uint8_t *input, uint64_t size) {
    const uint8_t *cursor = input;
    EVP_PKEY *public_key;
    if (input == NULL || size == UINT64_C(0) || size > (uint64_t)LONG_MAX) {
        return NULL;
    }
    public_key = d2i_PUBKEY(NULL, &cursor, (long)size);
    if (public_key == NULL || cursor != input + size) {
        EVP_PKEY_free(public_key);
        return NULL;
    }
    return public_key;
}

int32_t wirestack_tls_private_key_validate_pkcs8(
    const uint8_t *input,
    uint64_t size
) {
    EVP_PKEY *private_key = parse_exact_pkcs8(input, size);
    if (private_key == NULL) {
        return WIRESTACK_TLS_PROVIDER_CERTIFICATE_INVALID;
    }
    EVP_PKEY_free(private_key);
    return WIRESTACK_TLS_PROVIDER_OK;
}

int32_t wirestack_tls_identity_validate_pkcs8(
    const uint8_t *leaf_certificate,
    uint64_t leaf_certificate_size,
    const uint8_t *private_key,
    uint64_t private_key_size
) {
    X509 *certificate = parse_exact_x509(leaf_certificate, leaf_certificate_size);
    EVP_PKEY *key = parse_exact_pkcs8(private_key, private_key_size);
    int matches;
    if (certificate == NULL || key == NULL) {
        X509_free(certificate);
        EVP_PKEY_free(key);
        return WIRESTACK_TLS_PROVIDER_CERTIFICATE_INVALID;
    }
    ERR_clear_error();
    matches = X509_check_private_key(certificate, key);
    X509_free(certificate);
    EVP_PKEY_free(key);
    return matches == 1
        ? WIRESTACK_TLS_PROVIDER_OK
        : WIRESTACK_TLS_PROVIDER_CERTIFICATE_INVALID;
}

int32_t wirestack_tls_identity_validate_spki(
    const uint8_t *leaf_certificate,
    uint64_t leaf_certificate_size,
    const uint8_t *subject_public_key_info,
    uint64_t subject_public_key_info_size
) {
    X509 *certificate = parse_exact_x509(leaf_certificate, leaf_certificate_size);
    EVP_PKEY *expected = parse_exact_spki(
        subject_public_key_info,
        subject_public_key_info_size
    );
    EVP_PKEY *actual;
    int matches;
    if (certificate == NULL || expected == NULL) {
        X509_free(certificate);
        EVP_PKEY_free(expected);
        return WIRESTACK_TLS_PROVIDER_CERTIFICATE_INVALID;
    }
    actual = X509_get_pubkey(certificate);
    matches = actual != NULL && EVP_PKEY_cmp(actual, expected) == 1;
    EVP_PKEY_free(actual);
    EVP_PKEY_free(expected);
    X509_free(certificate);
    return matches
        ? WIRESTACK_TLS_PROVIDER_OK
        : WIRESTACK_TLS_PROVIDER_CERTIFICATE_INVALID;
}

uint32_t wirestack_tls_provider_abi_version(void) {
    return UINT32_C(1);
}

int32_t wirestack_tls_provider_create(uint64_t *out_handle) {
    struct wirestack_tls_provider *provider;
    time_t created_at;
    if (out_handle == NULL) {
        return WIRESTACK_TLS_PROVIDER_INVALID_ARGUMENT;
    }
    *out_handle = UINT64_C(0);
    provider = (struct wirestack_tls_provider *)calloc(1, sizeof(*provider));
    if (provider == NULL) {
        return WIRESTACK_TLS_PROVIDER_OUT_OF_MEMORY;
    }
    if (RAND_bytes(provider->ticket_key, sizeof(provider->ticket_key)) != 1) {
        OPENSSL_cleanse(provider, sizeof(*provider));
        free(provider);
        return WIRESTACK_TLS_PROVIDER_RANDOM_FAILED;
    }
    created_at = time(NULL);
    provider->ticket_key_created_at = created_at > 0 ? (uint64_t)created_at : UINT64_C(0);
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
    OPENSSL_cleanse(provider->ticket_key, sizeof(provider->ticket_key));
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

const char *wirestack_tls_provider_build_fingerprint(uint64_t handle) {
    return provider_from_handle(handle) == NULL ? NULL : WIRESTACK_TLS_BUILD_FINGERPRINT;
}

const char *wirestack_tls_provider_backend(uint64_t handle) {
    return provider_from_handle(handle) == NULL ? NULL : "aws-lc-static";
}

const char *wirestack_tls_provider_patch_level(uint64_t handle) {
    return provider_from_handle(handle) == NULL ? NULL : "abi-1;patches=none";
}

const char *wirestack_tls_provider_target_triple(uint64_t handle) {
    if (provider_from_handle(handle) == NULL) {
        return NULL;
    }
#if defined(__x86_64__)
    return "x86_64-unknown-linux-gnu";
#elif defined(__aarch64__)
    return "aarch64-unknown-linux-gnu";
#else
    return "unknown-unknown-linux-gnu";
#endif
}

int32_t wirestack_tls_provider_external_openssl_dependency(uint64_t handle) {
    return provider_from_handle(handle) == NULL ? -1 : 0;
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
    struct wirestack_tls_provider *provider = provider_from_handle(provider_handle);
    struct wirestack_tls_engine *engine = NULL;
    BIO *incoming = NULL;
    BIO *outgoing = NULL;
    int minimum_version;
    int maximum_version;
    if (provider == NULL || out_engine_handle == NULL ||
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
    engine->role = role;
    engine->matched_pin_index = -1;
    clear_last_error(engine);
    SSL_CTX_set_early_data_enabled(engine->context, 0);
    if (role == WIRESTACK_TLS_ENGINE_CLIENT) {
        SSL_CTX_set_session_cache_mode(engine->context, SSL_SESS_CACHE_CLIENT);
        SSL_CTX_sess_set_new_cb(engine->context, wirestack_new_session);
    } else {
        time_t observed_at = time(NULL);
        uint64_t now = observed_at > 0 ? (uint64_t)observed_at : UINT64_C(0);
        if (provider->ticket_key_created_at == UINT64_C(0) && now != UINT64_C(0)) {
            provider->ticket_key_created_at = now;
        } else if (provider->ticket_key_created_at != UINT64_C(0) &&
            now > provider->ticket_key_created_at &&
            now - provider->ticket_key_created_at >=
                (uint64_t)WIRESTACK_TLS_TICKET_KEY_ROTATION_SECONDS) {
            if (RAND_bytes(provider->ticket_key, sizeof(provider->ticket_key)) != 1) {
                SSL_CTX_free(engine->context);
                OPENSSL_cleanse(engine, sizeof(*engine));
                free(engine);
                return WIRESTACK_TLS_PROVIDER_RANDOM_FAILED;
            }
            provider->ticket_key_created_at = now;
        }
        SSL_CTX_set_session_cache_mode(
            engine->context,
            SSL_SESS_CACHE_SERVER | SSL_SESS_CACHE_NO_INTERNAL
        );
        SSL_CTX_set_num_tickets(engine->context, 1u);
        if (SSL_CTX_set_tlsext_ticket_keys(
                engine->context,
                provider->ticket_key,
                sizeof(provider->ticket_key)
            ) != 1) {
            SSL_CTX_free(engine->context);
            OPENSSL_cleanse(engine, sizeof(*engine));
            free(engine);
            return WIRESTACK_TLS_PROVIDER_ENGINE_FAILED;
        }
    }
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
    SSL_set_app_data(engine->ssl, engine);
    SSL_set_early_data_enabled(engine->ssl, 0);
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
    clear_sensitive_buffer(&engine->signer_input, &engine->signer_input_size);
    clear_sensitive_buffer(&engine->signer_signature, &engine->signer_signature_size);
    clear_sensitive_buffer(&engine->pending_session, &engine->pending_session_size);
    free(engine->server_alpn_protocols);
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
    X509 *certificate;
    int result;
    if (engine == NULL || input == NULL || size == UINT64_C(0) ||
        size > (uint64_t)LONG_MAX) {
        return WIRESTACK_TLS_PROVIDER_INVALID_ARGUMENT;
    }
    certificate = parse_exact_x509(input, size);
    if (certificate == NULL) {
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

int32_t wirestack_tls_engine_configure_client_authentication(
    uint64_t engine_handle,
    int32_t required
) {
    struct wirestack_tls_engine *engine = engine_from_handle(engine_handle);
    int mode;
    if (engine == NULL || engine->role != WIRESTACK_TLS_ENGINE_SERVER ||
        (required != 0 && required != 1)) {
        return WIRESTACK_TLS_PROVIDER_INVALID_ARGUMENT;
    }
    mode = SSL_VERIFY_PEER;
    if (required != 0) {
        mode |= SSL_VERIFY_FAIL_IF_NO_PEER_CERT;
    }
    SSL_set_verify_depth(engine->ssl, 10);
    SSL_set_verify(engine->ssl, mode, NULL);
    return WIRESTACK_TLS_PROVIDER_OK;
}

int32_t wirestack_tls_engine_set_alpn_protocols(
    uint64_t engine_handle,
    const uint8_t *protocols,
    uint64_t protocols_size
) {
    struct wirestack_tls_engine *engine = engine_from_handle(engine_handle);
    uint8_t *copy;
    if (engine == NULL || protocols_size > (uint64_t)SIZE_MAX ||
        !valid_alpn_wire_list(protocols, (size_t)protocols_size)) {
        return WIRESTACK_TLS_PROVIDER_INVALID_ARGUMENT;
    }
    if (engine->role == WIRESTACK_TLS_ENGINE_CLIENT) {
        if (SSL_set_alpn_protos(engine->ssl, protocols, (size_t)protocols_size) != 0) {
            return WIRESTACK_TLS_PROVIDER_ENGINE_FAILED;
        }
    } else {
        copy = (uint8_t *)malloc((size_t)protocols_size);
        if (copy == NULL) {
            return WIRESTACK_TLS_PROVIDER_OUT_OF_MEMORY;
        }
        memcpy(copy, protocols, (size_t)protocols_size);
        free(engine->server_alpn_protocols);
        engine->server_alpn_protocols = copy;
        engine->server_alpn_protocols_size = (size_t)protocols_size;
        SSL_CTX_set_alpn_select_cb(engine->context, wirestack_alpn_select, engine);
    }
    engine->alpn_required = 1;
    return WIRESTACK_TLS_PROVIDER_OK;
}

int32_t wirestack_tls_engine_set_protocol_versions(
    uint64_t engine_handle,
    int32_t minimum_tls_version,
    int32_t maximum_tls_version
) {
    struct wirestack_tls_engine *engine = engine_from_handle(engine_handle);
    int minimum_version;
    int maximum_version;
    if (engine == NULL ||
        (minimum_tls_version != 12 && minimum_tls_version != 13) ||
        (maximum_tls_version != 12 && maximum_tls_version != 13) ||
        minimum_tls_version > maximum_tls_version) {
        return WIRESTACK_TLS_PROVIDER_INVALID_ARGUMENT;
    }
    minimum_version = minimum_tls_version == 12 ? TLS1_2_VERSION : TLS1_3_VERSION;
    maximum_version = maximum_tls_version == 12 ? TLS1_2_VERSION : TLS1_3_VERSION;
    return SSL_set_min_proto_version(engine->ssl, minimum_version) &&
        SSL_set_max_proto_version(engine->ssl, maximum_version)
        ? WIRESTACK_TLS_PROVIDER_OK
        : WIRESTACK_TLS_PROVIDER_ENGINE_FAILED;
}

int32_t wirestack_tls_engine_set_session_id_context(
    uint64_t engine_handle,
    const uint8_t *context,
    uint64_t context_size
) {
    struct wirestack_tls_engine *engine = engine_from_handle(engine_handle);
    if (engine == NULL || engine->role != WIRESTACK_TLS_ENGINE_SERVER ||
        context == NULL || context_size == UINT64_C(0) || context_size > 32u) {
        return WIRESTACK_TLS_PROVIDER_INVALID_ARGUMENT;
    }
    return SSL_set_session_id_context(engine->ssl, context, (size_t)context_size) == 1
        ? WIRESTACK_TLS_PROVIDER_OK
        : WIRESTACK_TLS_PROVIDER_ENGINE_FAILED;
}

int32_t wirestack_tls_engine_offer_session(
    uint64_t engine_handle,
    const uint8_t *session_bytes,
    uint64_t session_size
) {
    struct wirestack_tls_engine *engine = engine_from_handle(engine_handle);
    SSL_SESSION *session;
    SSL_SESSION *without_early_data;
    int result;
    if (engine == NULL || engine->role != WIRESTACK_TLS_ENGINE_CLIENT ||
        session_bytes == NULL || session_size == UINT64_C(0) ||
        session_size > WIRESTACK_TLS_MAXIMUM_SESSION_BYTES ||
        session_size > (uint64_t)SIZE_MAX) {
        return WIRESTACK_TLS_PROVIDER_INVALID_ARGUMENT;
    }
    session = SSL_SESSION_from_bytes(
        session_bytes,
        (size_t)session_size,
        engine->context
    );
    if (session == NULL || SSL_SESSION_is_resumable(session) != 1) {
        SSL_SESSION_free(session);
        return WIRESTACK_TLS_PROVIDER_ENGINE_FAILED;
    }
    without_early_data = SSL_SESSION_copy_without_early_data(session);
    SSL_SESSION_free(session);
    if (without_early_data == NULL) {
        return WIRESTACK_TLS_PROVIDER_ENGINE_FAILED;
    }
    result = SSL_set_session(engine->ssl, without_early_data);
    SSL_SESSION_free(without_early_data);
    return result == 1
        ? WIRESTACK_TLS_PROVIDER_OK
        : WIRESTACK_TLS_PROVIDER_ENGINE_FAILED;
}

int32_t wirestack_tls_engine_pending_session(
    uint64_t engine_handle,
    uint8_t *output,
    uint64_t output_capacity,
    uint64_t *out_required_size,
    uint64_t *out_lifetime_seconds,
    int32_t *out_single_use
) {
    struct wirestack_tls_engine *engine = engine_from_handle(engine_handle);
    if (engine == NULL || engine->role != WIRESTACK_TLS_ENGINE_CLIENT ||
        out_required_size == NULL || out_lifetime_seconds == NULL ||
        out_single_use == NULL ||
        (output_capacity != UINT64_C(0) && output == NULL)) {
        return WIRESTACK_TLS_PROVIDER_INVALID_ARGUMENT;
    }
    *out_required_size = (uint64_t)engine->pending_session_size;
    *out_lifetime_seconds = engine->pending_session_lifetime_seconds;
    *out_single_use = engine->pending_session_single_use;
    if (output == NULL || output_capacity == UINT64_C(0) ||
        engine->pending_session_size == 0u) {
        return WIRESTACK_TLS_PROVIDER_OK;
    }
    if (output_capacity < (uint64_t)engine->pending_session_size) {
        return WIRESTACK_TLS_PROVIDER_LIMIT_EXCEEDED;
    }
    memcpy(output, engine->pending_session, engine->pending_session_size);
    clear_sensitive_buffer(&engine->pending_session, &engine->pending_session_size);
    engine->pending_session_lifetime_seconds = UINT64_C(0);
    engine->pending_session_single_use = 0;
    return WIRESTACK_TLS_PROVIDER_OK;
}

int32_t wirestack_tls_engine_enable_server_name_selection(uint64_t engine_handle) {
    struct wirestack_tls_engine *engine = engine_from_handle(engine_handle);
    if (engine == NULL || engine->role != WIRESTACK_TLS_ENGINE_SERVER ||
        engine->server_selection_state != WIRESTACK_TLS_SERVER_SELECTION_DISABLED) {
        return WIRESTACK_TLS_PROVIDER_INVALID_ARGUMENT;
    }
    engine->server_selection_state = WIRESTACK_TLS_SERVER_SELECTION_IDLE;
    SSL_CTX_set_select_certificate_cb(engine->context, wirestack_select_server_certificate);
    return WIRESTACK_TLS_PROVIDER_OK;
}

int32_t wirestack_tls_engine_server_name_selection_request(
    uint64_t engine_handle,
    uint8_t *output,
    uint64_t output_capacity,
    uint64_t *out_required_size
) {
    struct wirestack_tls_engine *engine = engine_from_handle(engine_handle);
    if (engine == NULL || out_required_size == NULL ||
        engine->server_selection_state != WIRESTACK_TLS_SERVER_SELECTION_REQUESTED ||
        (output_capacity != UINT64_C(0) && output == NULL)) {
        return WIRESTACK_TLS_PROVIDER_INVALID_ARGUMENT;
    }
    *out_required_size = (uint64_t)engine->requested_server_name_size;
    if (output == NULL || output_capacity == UINT64_C(0)) {
        return WIRESTACK_TLS_PROVIDER_OK;
    }
    if (output_capacity < (uint64_t)engine->requested_server_name_size) {
        return WIRESTACK_TLS_PROVIDER_LIMIT_EXCEEDED;
    }
    memcpy(output, engine->requested_server_name, engine->requested_server_name_size);
    return WIRESTACK_TLS_PROVIDER_OK;
}

int32_t wirestack_tls_engine_complete_server_name_selection(uint64_t engine_handle) {
    struct wirestack_tls_engine *engine = engine_from_handle(engine_handle);
    if (engine == NULL ||
        engine->server_selection_state != WIRESTACK_TLS_SERVER_SELECTION_REQUESTED) {
        return WIRESTACK_TLS_PROVIDER_INVALID_ARGUMENT;
    }
    engine->server_selection_state = WIRESTACK_TLS_SERVER_SELECTION_READY;
    return WIRESTACK_TLS_PROVIDER_OK;
}

int32_t wirestack_tls_engine_fail_server_name_selection(uint64_t engine_handle) {
    struct wirestack_tls_engine *engine = engine_from_handle(engine_handle);
    if (engine == NULL ||
        engine->server_selection_state != WIRESTACK_TLS_SERVER_SELECTION_REQUESTED) {
        return WIRESTACK_TLS_PROVIDER_INVALID_ARGUMENT;
    }
    engine->server_selection_state = WIRESTACK_TLS_SERVER_SELECTION_FAILED;
    return WIRESTACK_TLS_PROVIDER_OK;
}

int32_t wirestack_tls_engine_set_identity_pkcs8(
    uint64_t engine_handle,
    const uint8_t *leaf_certificate,
    uint64_t leaf_certificate_size,
    const uint8_t *private_key,
    uint64_t private_key_size
) {
    struct wirestack_tls_engine *engine = engine_from_handle(engine_handle);
    X509 *certificate;
    EVP_PKEY *key;
    int result;
    if (engine == NULL) {
        return WIRESTACK_TLS_PROVIDER_INVALID_ARGUMENT;
    }
    certificate = parse_exact_x509(leaf_certificate, leaf_certificate_size);
    key = parse_exact_pkcs8(private_key, private_key_size);
    if (certificate == NULL || key == NULL) {
        X509_free(certificate);
        EVP_PKEY_free(key);
        return WIRESTACK_TLS_PROVIDER_CERTIFICATE_INVALID;
    }
    ERR_clear_error();
    result = SSL_use_certificate(engine->ssl, certificate) == 1 &&
        SSL_use_PrivateKey(engine->ssl, key) == 1 &&
        SSL_check_private_key(engine->ssl) == 1;
    X509_free(certificate);
    EVP_PKEY_free(key);
    return result == 1
        ? WIRESTACK_TLS_PROVIDER_OK
        : WIRESTACK_TLS_PROVIDER_CERTIFICATE_INVALID;
}

int32_t wirestack_tls_engine_add_identity_chain_certificate_der(
    uint64_t engine_handle,
    const uint8_t *certificate,
    uint64_t certificate_size
) {
    struct wirestack_tls_engine *engine = engine_from_handle(engine_handle);
    X509 *parsed;
    int result;
    if (engine == NULL) {
        return WIRESTACK_TLS_PROVIDER_INVALID_ARGUMENT;
    }
    parsed = parse_exact_x509(certificate, certificate_size);
    if (parsed == NULL) {
        return WIRESTACK_TLS_PROVIDER_CERTIFICATE_INVALID;
    }
    ERR_clear_error();
    result = SSL_add1_chain_cert(engine->ssl, parsed);
    X509_free(parsed);
    return result == 1
        ? WIRESTACK_TLS_PROVIDER_OK
        : WIRESTACK_TLS_PROVIDER_CERTIFICATE_INVALID;
}

int32_t wirestack_tls_engine_set_external_signer(
    uint64_t engine_handle,
    const uint8_t *leaf_certificate,
    uint64_t leaf_certificate_size,
    const uint16_t *signature_algorithms,
    uint64_t signature_algorithm_count
) {
    struct wirestack_tls_engine *engine = engine_from_handle(engine_handle);
    X509 *certificate;
    int result;
    if (engine == NULL || signature_algorithms == NULL ||
        signature_algorithm_count == UINT64_C(0) ||
        signature_algorithm_count > UINT64_C(16) ||
        signature_algorithm_count > (uint64_t)SIZE_MAX) {
        return WIRESTACK_TLS_PROVIDER_INVALID_ARGUMENT;
    }
    certificate = parse_exact_x509(leaf_certificate, leaf_certificate_size);
    if (certificate == NULL) {
        return WIRESTACK_TLS_PROVIDER_CERTIFICATE_INVALID;
    }
    ERR_clear_error();
    result = SSL_use_certificate(engine->ssl, certificate) == 1 &&
        SSL_set_signing_algorithm_prefs(
            engine->ssl,
            signature_algorithms,
            (size_t)signature_algorithm_count
        ) == 1;
    X509_free(certificate);
    if (result != 1) {
        return WIRESTACK_TLS_PROVIDER_CERTIFICATE_INVALID;
    }
    SSL_set_private_key_method(engine->ssl, &WIRESTACK_EXTERNAL_KEY_METHOD);
    return WIRESTACK_TLS_PROVIDER_OK;
}

int32_t wirestack_tls_engine_external_signature_request(
    uint64_t engine_handle,
    uint16_t *out_signature_algorithm,
    uint8_t *output,
    uint64_t output_capacity,
    uint64_t *out_required_size
) {
    struct wirestack_tls_engine *engine = engine_from_handle(engine_handle);
    if (engine == NULL || out_signature_algorithm == NULL ||
        out_required_size == NULL ||
        engine->signer_state != WIRESTACK_TLS_SIGNER_REQUESTED ||
        (output_capacity != UINT64_C(0) && output == NULL)) {
        return WIRESTACK_TLS_PROVIDER_INVALID_ARGUMENT;
    }
    *out_signature_algorithm = engine->signer_algorithm;
    *out_required_size = (uint64_t)engine->signer_input_size;
    if (output == NULL || output_capacity == UINT64_C(0)) {
        return WIRESTACK_TLS_PROVIDER_OK;
    }
    if (output_capacity < (uint64_t)engine->signer_input_size) {
        return WIRESTACK_TLS_PROVIDER_LIMIT_EXCEEDED;
    }
    memcpy(output, engine->signer_input, engine->signer_input_size);
    return WIRESTACK_TLS_PROVIDER_OK;
}

int32_t wirestack_tls_engine_complete_external_signature(
    uint64_t engine_handle,
    const uint8_t *signature,
    uint64_t signature_size
) {
    struct wirestack_tls_engine *engine = engine_from_handle(engine_handle);
    if (engine == NULL || signature == NULL || signature_size == UINT64_C(0) ||
        signature_size > WIRESTACK_TLS_MAXIMUM_SIGNATURE ||
        signature_size > (uint64_t)SIZE_MAX ||
        engine->signer_state != WIRESTACK_TLS_SIGNER_REQUESTED) {
        return WIRESTACK_TLS_PROVIDER_INVALID_ARGUMENT;
    }
    engine->signer_signature = (uint8_t *)malloc((size_t)signature_size);
    if (engine->signer_signature == NULL) {
        return WIRESTACK_TLS_PROVIDER_OUT_OF_MEMORY;
    }
    memcpy(engine->signer_signature, signature, (size_t)signature_size);
    engine->signer_signature_size = (size_t)signature_size;
    engine->signer_state = WIRESTACK_TLS_SIGNER_READY;
    return WIRESTACK_TLS_PROVIDER_OK;
}

int32_t wirestack_tls_engine_fail_external_signature(uint64_t engine_handle) {
    struct wirestack_tls_engine *engine = engine_from_handle(engine_handle);
    if (engine == NULL || engine->signer_state != WIRESTACK_TLS_SIGNER_REQUESTED) {
        return WIRESTACK_TLS_PROVIDER_INVALID_ARGUMENT;
    }
    engine->signer_state = WIRESTACK_TLS_SIGNER_FAILED;
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
    clear_last_error(engine);
    ERR_clear_error();
    result = SSL_do_handshake(engine->ssl);
    if (result == 1) {
        const uint8_t *selected_alpn = NULL;
        unsigned selected_alpn_size = 0;
        if (engine->role == WIRESTACK_TLS_ENGINE_SERVER &&
            SSL_version(engine->ssl) == TLS1_3_VERSION &&
            engine->post_handshake_tickets_flushed == 0) {
            int ticket_result = SSL_write(engine->ssl, NULL, 0);
            if (ticket_result < 0 &&
                SSL_get_error(engine->ssl, ticket_result) != SSL_ERROR_WANT_WRITE) {
                return WIRESTACK_TLS_PROVIDER_ENGINE_FAILED;
            }
            engine->post_handshake_tickets_flushed = 1;
        }
        SSL_get0_alpn_selected(engine->ssl, &selected_alpn, &selected_alpn_size);
        if (engine->alpn_required != 0 && selected_alpn_size == 0u) {
            engine->last_error_class = WIRESTACK_TLS_ERROR_NO_SHARED_ALPN;
            return WIRESTACK_TLS_PROVIDER_ENGINE_FAILED;
        }
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
    if (error == SSL_ERROR_WANT_PRIVATE_KEY_OPERATION) {
        *out_step = WIRESTACK_TLS_ENGINE_NEED_SIGNATURE;
        return WIRESTACK_TLS_PROVIDER_OK;
    }
    if (error == SSL_ERROR_PENDING_CERTIFICATE) {
        *out_step = WIRESTACK_TLS_ENGINE_NEED_SERVER_SELECTION;
        return WIRESTACK_TLS_PROVIDER_OK;
    }
    capture_last_error(engine);
    return WIRESTACK_TLS_PROVIDER_ENGINE_FAILED;
}

int32_t wirestack_tls_engine_last_error(
    uint64_t engine_handle,
    int32_t *out_error_class,
    int64_t *out_native_reason,
    int64_t *out_verify_result,
    int32_t *out_peer_alert
) {
    struct wirestack_tls_engine *engine = engine_from_handle(engine_handle);
    if (engine == NULL || out_error_class == NULL || out_native_reason == NULL ||
        out_verify_result == NULL || out_peer_alert == NULL) {
        return WIRESTACK_TLS_PROVIDER_INVALID_ARGUMENT;
    }
    *out_error_class = engine->last_error_class;
    *out_native_reason = engine->last_native_reason;
    *out_verify_result = engine->last_verify_result;
    *out_peer_alert = engine->last_peer_alert;
    return WIRESTACK_TLS_PROVIDER_OK;
}

int32_t wirestack_tls_engine_handshake_info(
    uint64_t engine_handle,
    int32_t *out_tls_version,
    uint8_t *cipher_name,
    uint64_t cipher_name_capacity,
    uint64_t *out_cipher_name_size,
    uint8_t *negotiated_alpn,
    uint64_t negotiated_alpn_capacity,
    uint64_t *out_negotiated_alpn_size,
    int32_t *out_session_reused,
    int64_t *out_matched_pin_index
) {
    struct wirestack_tls_engine *engine = engine_from_handle(engine_handle);
    const SSL_CIPHER *cipher;
    const char *cipher_value;
    const uint8_t *alpn_value = NULL;
    unsigned alpn_size = 0;
    size_t cipher_size;
    int version;
    if (engine == NULL || out_tls_version == NULL || out_cipher_name_size == NULL ||
        out_negotiated_alpn_size == NULL || out_session_reused == NULL ||
        out_matched_pin_index == NULL || !SSL_is_init_finished(engine->ssl) ||
        (cipher_name_capacity != UINT64_C(0) && cipher_name == NULL) ||
        (negotiated_alpn_capacity != UINT64_C(0) && negotiated_alpn == NULL)) {
        return WIRESTACK_TLS_PROVIDER_INVALID_ARGUMENT;
    }
    version = SSL_version(engine->ssl);
    if (version == TLS1_2_VERSION) {
        *out_tls_version = 12;
    } else if (version == TLS1_3_VERSION) {
        *out_tls_version = 13;
    } else {
        return WIRESTACK_TLS_PROVIDER_ENGINE_FAILED;
    }
    cipher = SSL_get_current_cipher(engine->ssl);
    cipher_value = cipher == NULL ? NULL : SSL_CIPHER_standard_name(cipher);
    if (cipher_value == NULL) {
        return WIRESTACK_TLS_PROVIDER_ENGINE_FAILED;
    }
    cipher_size = strlen(cipher_value);
    SSL_get0_alpn_selected(engine->ssl, &alpn_value, &alpn_size);
    *out_cipher_name_size = (uint64_t)cipher_size;
    *out_negotiated_alpn_size = (uint64_t)alpn_size;
    *out_session_reused = SSL_session_reused(engine->ssl) != 0 ? 1 : 0;
    *out_matched_pin_index = (int64_t)engine->matched_pin_index;
    if (cipher_name == NULL && cipher_name_capacity == UINT64_C(0) &&
        negotiated_alpn == NULL && negotiated_alpn_capacity == UINT64_C(0)) {
        return WIRESTACK_TLS_PROVIDER_OK;
    }
    if (cipher_name_capacity < (uint64_t)cipher_size ||
        negotiated_alpn_capacity < (uint64_t)alpn_size) {
        return WIRESTACK_TLS_PROVIDER_LIMIT_EXCEEDED;
    }
    memcpy(cipher_name, cipher_value, cipher_size);
    if (alpn_size != 0u) {
        memcpy(negotiated_alpn, alpn_value, alpn_size);
    }
    return WIRESTACK_TLS_PROVIDER_OK;
}

int32_t wirestack_tls_engine_peer_chain_der(
    uint64_t engine_handle,
    uint8_t *output,
    uint64_t output_capacity,
    uint64_t *out_required_size,
    uint64_t *out_certificate_count
) {
    struct wirestack_tls_engine *engine = engine_from_handle(engine_handle);
    const STACK_OF(CRYPTO_BUFFER) *chain;
    size_t count;
    uint64_t required = UINT64_C(0);
    size_t index;
    if (engine == NULL || out_required_size == NULL || out_certificate_count == NULL ||
        !SSL_is_init_finished(engine->ssl) ||
        (output_capacity != UINT64_C(0) && output == NULL)) {
        return WIRESTACK_TLS_PROVIDER_INVALID_ARGUMENT;
    }
    chain = SSL_get0_peer_certificates(engine->ssl);
    count = chain == NULL ? 0u : sk_CRYPTO_BUFFER_num(chain);
    if (count > WIRESTACK_TLS_MAXIMUM_PEER_CHAIN_LENGTH) {
        return WIRESTACK_TLS_PROVIDER_LIMIT_EXCEEDED;
    }
    for (index = 0; index < count; index++) {
        const CRYPTO_BUFFER *certificate = sk_CRYPTO_BUFFER_value(chain, index);
        size_t certificate_size = CRYPTO_BUFFER_len(certificate);
        if (certificate_size == 0u ||
            certificate_size > WIRESTACK_TLS_MAXIMUM_PEER_CERTIFICATE_BYTES ||
            required > (uint64_t)WIRESTACK_TLS_MAXIMUM_PEER_CHAIN_BYTES -
                UINT64_C(4) - (uint64_t)certificate_size) {
            return WIRESTACK_TLS_PROVIDER_LIMIT_EXCEEDED;
        }
        required += UINT64_C(4) + (uint64_t)certificate_size;
    }
    *out_required_size = required;
    *out_certificate_count = (uint64_t)count;
    if (output == NULL && output_capacity == UINT64_C(0)) {
        return WIRESTACK_TLS_PROVIDER_OK;
    }
    if (output_capacity < required) {
        return WIRESTACK_TLS_PROVIDER_LIMIT_EXCEEDED;
    }
    required = UINT64_C(0);
    for (index = 0; index < count; index++) {
        const CRYPTO_BUFFER *certificate = sk_CRYPTO_BUFFER_value(chain, index);
        const uint8_t *data = CRYPTO_BUFFER_data(certificate);
        uint32_t certificate_size = (uint32_t)CRYPTO_BUFFER_len(certificate);
        output[required] = (uint8_t)(certificate_size >> 24);
        output[required + UINT64_C(1)] = (uint8_t)(certificate_size >> 16);
        output[required + UINT64_C(2)] = (uint8_t)(certificate_size >> 8);
        output[required + UINT64_C(3)] = (uint8_t)certificate_size;
        memcpy(output + required + UINT64_C(4), data, certificate_size);
        required += UINT64_C(4) + (uint64_t)certificate_size;
    }
    return WIRESTACK_TLS_PROVIDER_OK;
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
    clear_last_error(engine);
    ERR_clear_error();
    result = SSL_read(engine->ssl, output, (int)size);
    {
        int32_t status = classify_io_result(engine->ssl, result, out_read, out_step);
        if (status != WIRESTACK_TLS_PROVIDER_OK) {
            capture_last_error(engine);
        }
        return status;
    }
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
    clear_last_error(engine);
    ERR_clear_error();
    result = SSL_write(engine->ssl, input, (int)size);
    {
        int32_t status = classify_io_result(engine->ssl, result, out_written, out_step);
        if (status != WIRESTACK_TLS_PROVIDER_OK) {
            capture_last_error(engine);
        }
        return status;
    }
}

int32_t wirestack_tls_engine_shutdown_step(
    uint64_t engine_handle,
    int32_t *out_step
) {
    struct wirestack_tls_engine *engine = engine_from_handle(engine_handle);
    int result;
    int error;
    if (engine == NULL || out_step == NULL) {
        return WIRESTACK_TLS_PROVIDER_INVALID_ARGUMENT;
    }
    *out_step = -1;
    clear_last_error(engine);
    ERR_clear_error();
    result = SSL_shutdown(engine->ssl);
    if (result == 1) {
        *out_step = WIRESTACK_TLS_ENGINE_IO_COMPLETE;
        return WIRESTACK_TLS_PROVIDER_OK;
    }
    if (result == 0) {
        *out_step = WIRESTACK_TLS_ENGINE_IO_SHUTDOWN_SENT;
        return WIRESTACK_TLS_PROVIDER_OK;
    }
    error = SSL_get_error(engine->ssl, result);
    if (error == SSL_ERROR_WANT_READ) {
        *out_step = WIRESTACK_TLS_ENGINE_IO_WANT_READ;
        return WIRESTACK_TLS_PROVIDER_OK;
    }
    if (error == SSL_ERROR_WANT_WRITE) {
        *out_step = WIRESTACK_TLS_ENGINE_IO_WANT_WRITE;
        return WIRESTACK_TLS_PROVIDER_OK;
    }
    capture_last_error(engine);
    return WIRESTACK_TLS_PROVIDER_ENGINE_FAILED;
}
