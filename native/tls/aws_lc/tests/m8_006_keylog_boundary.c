#include "wirestack_tls_provider.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX_CERTIFICATE_BYTES (256u * 1024u)
#define MAX_PRIVATE_KEY_BYTES (64u * 1024u)
#define MAX_SERVER_NAME_BYTES 253u
#define TRANSFER_CHUNK_BYTES (16u * 1024u)
#define MAX_HANDSHAKE_CIPHERTEXT (1024u * 1024u)
#define MAX_HANDSHAKE_STEPS 256u
#define MAX_KEY_LOG_RECORDS 16u
#define MAX_KEY_LOG_LINE_BYTES 512u

#define LABEL_CLIENT_HANDSHAKE (UINT32_C(1) << 0)
#define LABEL_SERVER_HANDSHAKE (UINT32_C(1) << 1)
#define LABEL_CLIENT_TRAFFIC_0 (UINT32_C(1) << 2)
#define LABEL_SERVER_TRAFFIC_0 (UINT32_C(1) << 3)
#define LABEL_VALID (UINT32_C(1) << 31)
#define REQUIRED_TLS13_LABELS                                                   \
    (LABEL_CLIENT_HANDSHAKE | LABEL_SERVER_HANDSHAKE |                         \
     LABEL_CLIENT_TRAFFIC_0 | LABEL_SERVER_TRAFFIC_0)

static void clear_bytes(void *memory, size_t size) {
    volatile uint8_t *cursor = (volatile uint8_t *)memory;
    while (size != 0u) {
        *cursor++ = UINT8_C(0);
        size--;
    }
}

static int fail(const char *stage, int32_t status) {
    fprintf(stderr, "M8-006 provider boundary failure at %s (status=%d)\n",
            stage, (int)status);
    return 1;
}

static int read_bounded_file(
    const char *path,
    size_t maximum_size,
    uint8_t **out_bytes,
    size_t *out_size
) {
    FILE *stream = NULL;
    uint8_t *bytes = NULL;
    long length = 0;
    int result = 0;

    *out_bytes = NULL;
    *out_size = 0u;
    stream = fopen(path, "rb");
    if (stream == NULL || fseek(stream, 0, SEEK_END) != 0) {
        goto cleanup;
    }
    length = ftell(stream);
    if (length <= 0 || (uint64_t)length > (uint64_t)maximum_size ||
        fseek(stream, 0, SEEK_SET) != 0) {
        goto cleanup;
    }
    bytes = (uint8_t *)malloc((size_t)length);
    if (bytes == NULL || fread(bytes, 1u, (size_t)length, stream) != (size_t)length ||
        fgetc(stream) != EOF) {
        goto cleanup;
    }
    *out_bytes = bytes;
    *out_size = (size_t)length;
    bytes = NULL;
    result = 1;

cleanup:
    if (stream != NULL) {
        fclose(stream);
    }
    if (bytes != NULL) {
        clear_bytes(bytes, (size_t)length);
        free(bytes);
    }
    return result;
}

static int transfer_ciphertext(
    uint64_t source,
    uint64_t destination,
    uint8_t *buffer,
    uint64_t *total_transferred,
    uint64_t *out_moved
) {
    uint64_t pending = 0u;

    *out_moved = 0u;
    if (wirestack_tls_engine_pending_ciphertext(source, &pending) !=
        WIRESTACK_TLS_PROVIDER_OK) {
        return 0;
    }
    if (*total_transferred > MAX_HANDSHAKE_CIPHERTEXT ||
        pending > MAX_HANDSHAKE_CIPHERTEXT - *total_transferred) {
        return 0;
    }
    while (pending != 0u) {
        uint64_t requested = pending < TRANSFER_CHUNK_BYTES
            ? pending
            : TRANSFER_CHUNK_BYTES;
        uint64_t drained = 0u;
        uint64_t offset = 0u;
        if (wirestack_tls_engine_drain_ciphertext(
                source, buffer, requested, &drained) != WIRESTACK_TLS_PROVIDER_OK ||
            drained == 0u || drained > requested) {
            return 0;
        }
        while (offset != drained) {
            uint64_t written = 0u;
            if (wirestack_tls_engine_feed_ciphertext(
                    destination,
                    buffer + offset,
                    drained - offset,
                    &written) != WIRESTACK_TLS_PROVIDER_OK ||
                written == 0u || written > drained - offset) {
                return 0;
            }
            offset += written;
        }
        *total_transferred += drained;
        *out_moved += drained;
        pending -= drained;
    }
    return 1;
}

static int is_hex(const uint8_t *bytes, size_t size) {
    size_t index;
    for (index = 0u; index < size; index++) {
        uint8_t value = bytes[index];
        if (!((value >= (uint8_t)'0' && value <= (uint8_t)'9') ||
              (value >= (uint8_t)'a' && value <= (uint8_t)'f') ||
              (value >= (uint8_t)'A' && value <= (uint8_t)'F'))) {
            return 0;
        }
    }
    return 1;
}

static int is_label(const uint8_t *bytes, size_t size) {
    size_t index;
    if (size == 0u || size > 64u) {
        return 0;
    }
    for (index = 0u; index < size; index++) {
        uint8_t value = bytes[index];
        if (!((value >= (uint8_t)'A' && value <= (uint8_t)'Z') ||
              (value >= (uint8_t)'0' && value <= (uint8_t)'9') ||
              value == (uint8_t)'_')) {
            return 0;
        }
    }
    return 1;
}

static uint32_t validate_key_log_line(const uint8_t *line, size_t size) {
    static const struct {
        const char *name;
        uint32_t bit;
    } labels[] = {
        {"CLIENT_HANDSHAKE_TRAFFIC_SECRET", LABEL_CLIENT_HANDSHAKE},
        {"SERVER_HANDSHAKE_TRAFFIC_SECRET", LABEL_SERVER_HANDSHAKE},
        {"CLIENT_TRAFFIC_SECRET_0", LABEL_CLIENT_TRAFFIC_0},
        {"SERVER_TRAFFIC_SECRET_0", LABEL_SERVER_TRAFFIC_0},
    };
    const uint8_t *first_space;
    const uint8_t *second_space;
    size_t label_size;
    size_t random_size;
    size_t secret_size;
    size_t index;
    uint32_t bit = UINT32_C(0);

    if (size == 0u || size > MAX_KEY_LOG_LINE_BYTES ||
        memchr(line, '\n', size) != NULL || memchr(line, '\r', size) != NULL) {
        return UINT32_C(0);
    }
    first_space = (const uint8_t *)memchr(line, ' ', size);
    if (first_space == NULL) {
        return UINT32_C(0);
    }
    label_size = (size_t)(first_space - line);
    second_space = (const uint8_t *)memchr(
        first_space + 1,
        ' ',
        size - label_size - 1u
    );
    if (second_space == NULL) {
        return UINT32_C(0);
    }
    random_size = (size_t)(second_space - first_space - 1);
    secret_size = size - (size_t)(second_space - line) - 1u;
    if (!is_label(line, label_size) ||
        random_size != 64u || secret_size == 0u || (secret_size & 1u) != 0u ||
        memchr(second_space + 1, ' ', secret_size) != NULL ||
        !is_hex(first_space + 1, random_size) ||
        !is_hex(second_space + 1, secret_size)) {
        return UINT32_C(0);
    }
    for (index = 0u; index < sizeof(labels) / sizeof(labels[0]); index++) {
        size_t expected = strlen(labels[index].name);
        if (label_size == expected && memcmp(line, labels[index].name, expected) == 0) {
            bit = labels[index].bit;
            break;
        }
    }
    return LABEL_VALID | bit;
}

int main(int argc, char **argv) {
    static const char expected_server_name[] = "example.com";
    uint8_t *certificate = NULL;
    uint8_t *private_key = NULL;
    uint8_t *transport = NULL;
    uint8_t *server_name = NULL;
    uint8_t *key_log_line = NULL;
    size_t certificate_size = 0u;
    size_t private_key_size = 0u;
    uint64_t provider = UINT64_C(0);
    uint64_t client = UINT64_C(0);
    uint64_t server = UINT64_C(0);
    uint64_t required = UINT64_C(0);
    uint64_t total_transferred = UINT64_C(0);
    uint64_t moved = UINT64_C(0);
    uint64_t record_count = UINT64_C(0);
    uint32_t labels_seen = UINT32_C(0);
    int32_t client_step = -1;
    int32_t server_step = -1;
    int32_t status = WIRESTACK_TLS_PROVIDER_OK;
    int client_complete = 0;
    int server_complete = 0;
    unsigned iteration;
    int result = 1;

    if (argc != 3) {
        return fail("arguments", WIRESTACK_TLS_PROVIDER_INVALID_ARGUMENT);
    }
    if (!read_bounded_file(argv[1], MAX_CERTIFICATE_BYTES,
                           &certificate, &certificate_size) ||
        !read_bounded_file(argv[2], MAX_PRIVATE_KEY_BYTES,
                           &private_key, &private_key_size)) {
        fail("bounded identity input", WIRESTACK_TLS_PROVIDER_INVALID_ARGUMENT);
        goto cleanup;
    }
    transport = (uint8_t *)malloc(TRANSFER_CHUNK_BYTES);
    server_name = (uint8_t *)malloc(MAX_SERVER_NAME_BYTES);
    key_log_line = (uint8_t *)malloc(MAX_KEY_LOG_LINE_BYTES);
    if (transport == NULL || server_name == NULL || key_log_line == NULL) {
        fail("bounded temporary allocation", WIRESTACK_TLS_PROVIDER_OUT_OF_MEMORY);
        goto cleanup;
    }

    if (wirestack_tls_provider_abi_version() != UINT32_C(1)) {
        fail("provider ABI version", WIRESTACK_TLS_PROVIDER_INVALID_ARGUMENT);
        goto cleanup;
    }
    status = wirestack_tls_provider_create(&provider);
    if (status != WIRESTACK_TLS_PROVIDER_OK || provider == UINT64_C(0)) {
        fail("provider create", status);
        goto cleanup;
    }
    if ((wirestack_tls_provider_capabilities(provider) & WIRESTACK_TLS_CAP_KEY_LOG) == 0u) {
        fail("test-only capability", WIRESTACK_TLS_PROVIDER_INVALID_ARGUMENT);
        goto cleanup;
    }
    status = wirestack_tls_engine_create(
        provider, WIRESTACK_TLS_ENGINE_CLIENT, 13, 13, &client);
    if (status != WIRESTACK_TLS_PROVIDER_OK || client == UINT64_C(0)) {
        fail("client create", status);
        goto cleanup;
    }
    status = wirestack_tls_engine_create(
        provider, WIRESTACK_TLS_ENGINE_SERVER, 13, 13, &server);
    if (status != WIRESTACK_TLS_PROVIDER_OK || server == UINT64_C(0)) {
        fail("server create", status);
        goto cleanup;
    }

    status = wirestack_tls_engine_add_trust_anchor_der(
        client, certificate, (uint64_t)certificate_size);
    if (status != WIRESTACK_TLS_PROVIDER_OK) {
        fail("custom trust anchor", status);
        goto cleanup;
    }
    status = wirestack_tls_engine_set_server_name(client, expected_server_name);
    if (status != WIRESTACK_TLS_PROVIDER_OK) {
        fail("client SNI", status);
        goto cleanup;
    }
    status = wirestack_tls_engine_set_dns_reference_identity(client, expected_server_name);
    if (status != WIRESTACK_TLS_PROVIDER_OK) {
        fail("DNS reference identity", status);
        goto cleanup;
    }
    status = wirestack_tls_engine_enable_peer_verification(client);
    if (status != WIRESTACK_TLS_PROVIDER_OK) {
        fail("peer verification", status);
        goto cleanup;
    }
    status = wirestack_tls_engine_enable_server_name_selection(server);
    if (status != WIRESTACK_TLS_PROVIDER_OK) {
        fail("server-name selection", status);
        goto cleanup;
    }

    status = wirestack_tls_engine_handshake_step(client, &client_step);
    if (status != WIRESTACK_TLS_PROVIDER_OK ||
        (client_step != WIRESTACK_TLS_ENGINE_WANT_READ &&
         client_step != WIRESTACK_TLS_ENGINE_WANT_WRITE)) {
        fail("initial client handshake", status);
        goto cleanup;
    }
    if (!transfer_ciphertext(client, server, transport,
                             &total_transferred, &moved) || moved == UINT64_C(0)) {
        fail("initial ClientHello transfer", WIRESTACK_TLS_PROVIDER_ENGINE_FAILED);
        goto cleanup;
    }
    status = wirestack_tls_engine_handshake_step(server, &server_step);
    if (status != WIRESTACK_TLS_PROVIDER_OK ||
        server_step != WIRESTACK_TLS_ENGINE_NEED_SERVER_SELECTION) {
        fail("pending server selection", status);
        goto cleanup;
    }

    status = wirestack_tls_engine_server_name_selection_request(
        server, NULL, UINT64_C(0), &required);
    if (status != WIRESTACK_TLS_PROVIDER_OK ||
        required != (uint64_t)(sizeof(expected_server_name) - 1u)) {
        fail("server-name query", status);
        goto cleanup;
    }
    status = wirestack_tls_engine_server_name_selection_request(
        server, server_name, MAX_SERVER_NAME_BYTES, &required);
    if (status != WIRESTACK_TLS_PROVIDER_OK ||
        memcmp(server_name, expected_server_name, (size_t)required) != 0) {
        fail("server-name copy", status);
        goto cleanup;
    }

    status = wirestack_tls_engine_enable_key_log(server);
    if (status != WIRESTACK_TLS_PROVIDER_OK) {
        fail("key-log enable while selection pending", status);
        goto cleanup;
    }
    required = UINT64_MAX;
    status = wirestack_tls_engine_pending_key_log(
        server, NULL, UINT64_C(0), &required);
    if (status != WIRESTACK_TLS_PROVIDER_OK || required != UINT64_C(0)) {
        fail("no pre-key key-log records", status);
        goto cleanup;
    }
    status = wirestack_tls_engine_set_identity_pkcs8(
        server,
        certificate,
        (uint64_t)certificate_size,
        private_key,
        (uint64_t)private_key_size
    );
    if (status != WIRESTACK_TLS_PROVIDER_OK) {
        fail("selected server identity", status);
        goto cleanup;
    }
    status = wirestack_tls_engine_complete_server_name_selection(server);
    if (status != WIRESTACK_TLS_PROVIDER_OK) {
        fail("complete server selection", status);
        goto cleanup;
    }
    required = UINT64_MAX;
    status = wirestack_tls_engine_pending_key_log(
        server, NULL, UINT64_C(0), &required);
    if (status != WIRESTACK_TLS_PROVIDER_OK || required != UINT64_C(0)) {
        fail("no records before key generation", status);
        goto cleanup;
    }

    for (iteration = 0u; iteration < MAX_HANDSHAKE_STEPS; iteration++) {
        uint64_t iteration_moved = UINT64_C(0);
        if (!server_complete) {
            status = wirestack_tls_engine_handshake_step(server, &server_step);
            if (status != WIRESTACK_TLS_PROVIDER_OK ||
                (server_step != WIRESTACK_TLS_ENGINE_COMPLETE &&
                 server_step != WIRESTACK_TLS_ENGINE_WANT_READ &&
                 server_step != WIRESTACK_TLS_ENGINE_WANT_WRITE)) {
                fail("server handshake", status);
                goto cleanup;
            }
            server_complete = server_step == WIRESTACK_TLS_ENGINE_COMPLETE;
        }
        if (!transfer_ciphertext(server, client, transport,
                                 &total_transferred, &moved)) {
            fail("server ciphertext transfer", WIRESTACK_TLS_PROVIDER_ENGINE_FAILED);
            goto cleanup;
        }
        iteration_moved += moved;

        if (!client_complete) {
            status = wirestack_tls_engine_handshake_step(client, &client_step);
            if (status != WIRESTACK_TLS_PROVIDER_OK ||
                (client_step != WIRESTACK_TLS_ENGINE_COMPLETE &&
                 client_step != WIRESTACK_TLS_ENGINE_WANT_READ &&
                 client_step != WIRESTACK_TLS_ENGINE_WANT_WRITE)) {
                fail("client handshake", status);
                goto cleanup;
            }
            client_complete = client_step == WIRESTACK_TLS_ENGINE_COMPLETE;
        }
        if (!transfer_ciphertext(client, server, transport,
                                 &total_transferred, &moved)) {
            fail("client ciphertext transfer", WIRESTACK_TLS_PROVIDER_ENGINE_FAILED);
            goto cleanup;
        }
        iteration_moved += moved;

        if (client_complete && server_complete) {
            break;
        }
        if (iteration_moved == UINT64_C(0) &&
            client_step == WIRESTACK_TLS_ENGINE_WANT_READ &&
            server_step == WIRESTACK_TLS_ENGINE_WANT_READ) {
            fail("handshake deadlock", WIRESTACK_TLS_PROVIDER_ENGINE_FAILED);
            goto cleanup;
        }
    }
    if (!client_complete || !server_complete || iteration == MAX_HANDSHAKE_STEPS) {
        fail("bounded handshake completion", WIRESTACK_TLS_PROVIDER_LIMIT_EXCEEDED);
        goto cleanup;
    }
    {
        int32_t tls_version = 0;
        uint64_t cipher_size = UINT64_C(0);
        uint64_t alpn_size = UINT64_C(0);
        int32_t session_reused = -1;
        int64_t matched_pin = -2;
        status = wirestack_tls_engine_handshake_info(
            client,
            &tls_version,
            NULL,
            UINT64_C(0),
            &cipher_size,
            NULL,
            UINT64_C(0),
            &alpn_size,
            &session_reused,
            &matched_pin
        );
        if (status != WIRESTACK_TLS_PROVIDER_OK || tls_version != 13 ||
            cipher_size == UINT64_C(0) || alpn_size != UINT64_C(0) ||
            session_reused != 0 || matched_pin != -1) {
            fail("verified TLS 1.3 result", status);
            goto cleanup;
        }
    }

    for (record_count = UINT64_C(0);
         record_count < MAX_KEY_LOG_RECORDS;
         record_count++) {
        uint32_t label;
        required = UINT64_MAX;
        status = wirestack_tls_engine_pending_key_log(
            server, NULL, UINT64_C(0), &required);
        if (status != WIRESTACK_TLS_PROVIDER_OK) {
            fail("key-log size query", status);
            goto cleanup;
        }
        if (required == UINT64_C(0)) {
            break;
        }
        if (required > MAX_KEY_LOG_LINE_BYTES) {
            fail("bounded key-log record", WIRESTACK_TLS_PROVIDER_LIMIT_EXCEEDED);
            goto cleanup;
        }
        status = wirestack_tls_engine_pending_key_log(
            server, key_log_line, required, &required);
        if (status != WIRESTACK_TLS_PROVIDER_OK) {
            fail("key-log copy and consume", status);
            goto cleanup;
        }
        label = validate_key_log_line(key_log_line, (size_t)required);
        clear_bytes(key_log_line, MAX_KEY_LOG_LINE_BYTES);
        if (label == UINT32_C(0)) {
            fail("NSS key-log record shape", WIRESTACK_TLS_PROVIDER_ENGINE_FAILED);
            goto cleanup;
        }
        labels_seen |= label;
    }
    required = UINT64_MAX;
    status = wirestack_tls_engine_pending_key_log(
        server, NULL, UINT64_C(0), &required);
    if (status != WIRESTACK_TLS_PROVIDER_OK || required != UINT64_C(0) ||
        (labels_seen & REQUIRED_TLS13_LABELS) != REQUIRED_TLS13_LABELS) {
        fail("required TLS 1.3 labels and empty queue", status);
        goto cleanup;
    }
    status = wirestack_tls_engine_disable_key_log(server);
    if (status != WIRESTACK_TLS_PROVIDER_OK) {
        fail("key-log disable", status);
        goto cleanup;
    }
    status = wirestack_tls_engine_enable_key_log(server);
    if (status != WIRESTACK_TLS_PROVIDER_INVALID_ARGUMENT) {
        fail("post-completion capture rejection", status);
        goto cleanup;
    }

    puts("M8_006_KEYLOG_PROVIDER_BOUNDARY=PASS");
    result = 0;

cleanup:
    if (key_log_line != NULL) {
        clear_bytes(key_log_line, MAX_KEY_LOG_LINE_BYTES);
        free(key_log_line);
    }
    if (server_name != NULL) {
        clear_bytes(server_name, MAX_SERVER_NAME_BYTES);
        free(server_name);
    }
    if (transport != NULL) {
        clear_bytes(transport, TRANSFER_CHUNK_BYTES);
        free(transport);
    }
    if (server != UINT64_C(0)) {
        wirestack_tls_engine_destroy(server);
    }
    if (client != UINT64_C(0)) {
        wirestack_tls_engine_destroy(client);
    }
    if (provider != UINT64_C(0)) {
        wirestack_tls_provider_destroy(provider);
    }
    if (private_key != NULL) {
        clear_bytes(private_key, private_key_size);
        free(private_key);
    }
    if (certificate != NULL) {
        clear_bytes(certificate, certificate_size);
        free(certificate);
    }
    return result;
}
