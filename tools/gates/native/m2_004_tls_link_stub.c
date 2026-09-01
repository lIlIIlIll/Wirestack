/*
 * M2-004 resolver-test link support only.
 *
 * The root Cangjie package owns provider-neutral trust declarations, so CJPM
 * retains these three foreign references even when the resolver package is the
 * only test target. This archive is built only by the native Windows M2-004
 * gate. Every function fails closed and it is never a TLS provider or release
 * payload.
 */

#include <stdint.h>
#include <string.h>

#define WIRESTACK_TLS_TEST_STUB_UNAVAILABLE 6

int32_t wirestack_tls_sha256(
    const uint8_t *input,
    uint64_t size,
    uint8_t *output
) {
    (void)input;
    (void)size;
    if (output != NULL) {
        memset(output, 0, 32u);
    }
    return WIRESTACK_TLS_TEST_STUB_UNAVAILABLE;
}

int32_t wirestack_tls_certificate_validate_der(
    const uint8_t *input,
    uint64_t size,
    uint64_t maximum_extensions,
    uint64_t *output_extension_count
) {
    (void)input;
    (void)size;
    (void)maximum_extensions;
    if (output_extension_count != NULL) {
        *output_extension_count = 0u;
    }
    return WIRESTACK_TLS_TEST_STUB_UNAVAILABLE;
}

int32_t wirestack_tls_certificate_subject_alt_names(
    const uint8_t *input,
    uint64_t size,
    uint8_t *output,
    uint64_t output_capacity,
    uint64_t *output_required_size,
    uint64_t *output_dns_count,
    uint64_t *output_ip_count
) {
    (void)input;
    (void)size;
    (void)output;
    (void)output_capacity;
    if (output_required_size != NULL) {
        *output_required_size = 0u;
    }
    if (output_dns_count != NULL) {
        *output_dns_count = 0u;
    }
    if (output_ip_count != NULL) {
        *output_ip_count = 0u;
    }
    return WIRESTACK_TLS_TEST_STUB_UNAVAILABLE;
}
