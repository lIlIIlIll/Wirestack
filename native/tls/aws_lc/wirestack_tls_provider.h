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
    WIRESTACK_TLS_PROVIDER_ENGINE_FAILED = 5,
    WIRESTACK_TLS_PROVIDER_CERTIFICATE_INVALID = 6,
    WIRESTACK_TLS_PROVIDER_LIMIT_EXCEEDED = 7
};

enum wirestack_tls_engine_role {
    WIRESTACK_TLS_ENGINE_CLIENT = 0,
    WIRESTACK_TLS_ENGINE_SERVER = 1
};

enum wirestack_tls_engine_step {
    WIRESTACK_TLS_ENGINE_COMPLETE = 0,
    WIRESTACK_TLS_ENGINE_WANT_READ = 1,
    WIRESTACK_TLS_ENGINE_WANT_WRITE = 2,
    WIRESTACK_TLS_ENGINE_NEED_SIGNATURE = 3,
    WIRESTACK_TLS_ENGINE_NEED_SERVER_SELECTION = 4
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
int32_t wirestack_tls_sha256(
    const uint8_t *input,
    uint64_t size,
    uint8_t out_digest[32]
);
int32_t wirestack_tls_certificate_validate_der(
    const uint8_t *input,
    uint64_t size,
    uint64_t maximum_extensions,
    uint64_t *out_extension_count
);
int32_t wirestack_tls_certificate_subject_alt_names(
    const uint8_t *input,
    uint64_t size,
    uint8_t *output,
    uint64_t output_capacity,
    uint64_t *out_required_size,
    uint64_t *out_dns_count,
    uint64_t *out_ip_count
);
int32_t wirestack_tls_private_key_validate_pkcs8(
    const uint8_t *input,
    uint64_t size
);
int32_t wirestack_tls_identity_validate_pkcs8(
    const uint8_t *leaf_certificate,
    uint64_t leaf_certificate_size,
    const uint8_t *private_key,
    uint64_t private_key_size
);
int32_t wirestack_tls_identity_validate_spki(
    const uint8_t *leaf_certificate,
    uint64_t leaf_certificate_size,
    const uint8_t *subject_public_key_info,
    uint64_t subject_public_key_info_size
);

int32_t wirestack_tls_engine_create(
    uint64_t provider_handle,
    int32_t role,
    int32_t minimum_tls_version,
    int32_t maximum_tls_version,
    uint64_t *out_engine_handle
);
void wirestack_tls_engine_destroy(uint64_t engine_handle);
int32_t wirestack_tls_engine_add_trust_anchor_der(
    uint64_t engine_handle,
    const uint8_t *input,
    uint64_t size
);
int32_t wirestack_tls_engine_add_spki_sha256_pin(
    uint64_t engine_handle,
    const uint8_t digest[32],
    int32_t scope
);
int32_t wirestack_tls_engine_load_verify_locations(
    uint64_t engine_handle,
    const char *certificate_bundle,
    const char *hashed_certificate_directory
);
int32_t wirestack_tls_engine_load_verify_bundle(
    uint64_t engine_handle,
    const char *certificate_bundle
);
int32_t wirestack_tls_engine_load_verify_directory(
    uint64_t engine_handle,
    const char *hashed_certificate_directory
);
int32_t wirestack_tls_engine_set_server_name(
    uint64_t engine_handle,
    const char *server_name
);
int32_t wirestack_tls_engine_set_dns_reference_identity(
    uint64_t engine_handle,
    const char *dns_name
);
int32_t wirestack_tls_engine_set_ip_reference_identity(
    uint64_t engine_handle,
    const uint8_t *address,
    uint64_t size
);
int32_t wirestack_tls_engine_enable_peer_verification(uint64_t engine_handle);
int32_t wirestack_tls_engine_configure_client_authentication(
    uint64_t engine_handle,
    int32_t required
);
int32_t wirestack_tls_engine_set_alpn_protocols(
    uint64_t engine_handle,
    const uint8_t *protocols,
    uint64_t protocols_size
);
int32_t wirestack_tls_engine_set_protocol_versions(
    uint64_t engine_handle,
    int32_t minimum_tls_version,
    int32_t maximum_tls_version
);
int32_t wirestack_tls_engine_enable_server_name_selection(uint64_t engine_handle);
int32_t wirestack_tls_engine_server_name_selection_request(
    uint64_t engine_handle,
    uint8_t *output,
    uint64_t output_capacity,
    uint64_t *out_required_size
);
int32_t wirestack_tls_engine_complete_server_name_selection(uint64_t engine_handle);
int32_t wirestack_tls_engine_fail_server_name_selection(uint64_t engine_handle);
int32_t wirestack_tls_engine_set_identity_pkcs8(
    uint64_t engine_handle,
    const uint8_t *leaf_certificate,
    uint64_t leaf_certificate_size,
    const uint8_t *private_key,
    uint64_t private_key_size
);
int32_t wirestack_tls_engine_add_identity_chain_certificate_der(
    uint64_t engine_handle,
    const uint8_t *certificate,
    uint64_t certificate_size
);
int32_t wirestack_tls_engine_set_external_signer(
    uint64_t engine_handle,
    const uint8_t *leaf_certificate,
    uint64_t leaf_certificate_size,
    const uint16_t *signature_algorithms,
    uint64_t signature_algorithm_count
);
int32_t wirestack_tls_engine_external_signature_request(
    uint64_t engine_handle,
    uint16_t *out_signature_algorithm,
    uint8_t *output,
    uint64_t output_capacity,
    uint64_t *out_required_size
);
int32_t wirestack_tls_engine_complete_external_signature(
    uint64_t engine_handle,
    const uint8_t *signature,
    uint64_t signature_size
);
int32_t wirestack_tls_engine_fail_external_signature(uint64_t engine_handle);
int32_t wirestack_tls_engine_handshake_step(
    uint64_t engine_handle,
    int32_t *out_step
);
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
);
int32_t wirestack_tls_engine_peer_chain_der(
    uint64_t engine_handle,
    uint8_t *output,
    uint64_t output_capacity,
    uint64_t *out_required_size,
    uint64_t *out_certificate_count
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
