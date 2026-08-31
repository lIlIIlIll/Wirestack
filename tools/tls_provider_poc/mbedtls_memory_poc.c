#include <mbedtls/ssl.h>
#include <mbedtls/x509_crt.h>
#include <mbedtls/pk.h>
#include <mbedtls/error.h>
#include <psa/crypto.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX_STEPS 300000
#define RING_CAPACITY 2048
#define PAYLOAD_SIZE 32768
#define CLEANUP_CYCLES 10000

typedef struct {
    unsigned char data[RING_CAPACITY];
    size_t head;
    size_t length;
    int closed;
} Ring;

typedef struct {
    Ring *rx;
    Ring *tx;
} Endpoint;

typedef struct {
    mbedtls_ssl_context client;
    mbedtls_ssl_context server;
    Ring c2s;
    Ring s2c;
    Endpoint client_ep;
    Endpoint server_ep;
} Pair;

typedef struct {
    mbedtls_x509_crt ca;
    mbedtls_x509_crt server_cert;
    mbedtls_x509_crt client_cert;
    mbedtls_pk_context server_key;
    mbedtls_pk_context client_key;
} Material;

static int sni_seen = 0;
static int external_trust_decision = 0;
static unsigned int external_trust_calls = 0;

static int external_trust_callback(void *opaque, mbedtls_x509_crt *cert,
                                   int depth, uint32_t *flags) {
    (void)opaque;
    (void)cert;
    (void)depth;
    external_trust_calls++;
    if (external_trust_decision) *flags = 0;
    else *flags |= MBEDTLS_X509_BADCERT_NOT_TRUSTED;
    return 0;
}

static int ring_send(void *opaque, const unsigned char *buf, size_t len) {
    Endpoint *ep = (Endpoint *)opaque;
    Ring *ring = ep->tx;
    size_t free_space = RING_CAPACITY - ring->length;
    if (free_space == 0) return MBEDTLS_ERR_SSL_WANT_WRITE;
    size_t count = len < free_space ? len : free_space;
    size_t tail = (ring->head + ring->length) % RING_CAPACITY;
    size_t first = count < (RING_CAPACITY - tail) ? count : (RING_CAPACITY - tail);
    memcpy(ring->data + tail, buf, first);
    if (count > first) memcpy(ring->data, buf + first, count - first);
    ring->length += count;
    return (int)count;
}

static int ring_recv(void *opaque, unsigned char *buf, size_t len) {
    Endpoint *ep = (Endpoint *)opaque;
    Ring *ring = ep->rx;
    if (ring->length == 0) return ring->closed ? 0 : MBEDTLS_ERR_SSL_WANT_READ;
    size_t count = len < ring->length ? len : ring->length;
    size_t first = count < (RING_CAPACITY - ring->head) ? count : (RING_CAPACITY - ring->head);
    memcpy(buf, ring->data + ring->head, first);
    if (count > first) memcpy(buf + first, ring->data, count - first);
    ring->head = (ring->head + count) % RING_CAPACITY;
    ring->length -= count;
    return (int)count;
}

static int sni_callback(void *opaque, mbedtls_ssl_context *ssl,
                        const unsigned char *name, size_t name_len) {
    (void)opaque;
    (void)ssl;
    if (name_len == 9 && memcmp(name, "localhost", 9) == 0) sni_seen = 1;
    return 0;
}

static void material_init(Material *m) {
    memset(m, 0, sizeof(*m));
    mbedtls_x509_crt_init(&m->ca);
    mbedtls_x509_crt_init(&m->server_cert);
    mbedtls_x509_crt_init(&m->client_cert);
    mbedtls_pk_init(&m->server_key);
    mbedtls_pk_init(&m->client_key);
}

static void material_free(Material *m) {
    mbedtls_pk_free(&m->client_key);
    mbedtls_pk_free(&m->server_key);
    mbedtls_x509_crt_free(&m->client_cert);
    mbedtls_x509_crt_free(&m->server_cert);
    mbedtls_x509_crt_free(&m->ca);
}

static int load_material(Material *m, const char *server_cert, const char *server_key,
                         const char *ca, const char *client_cert, const char *client_key) {
    int ret;
    if ((ret = mbedtls_x509_crt_parse_file(&m->ca, ca)) != 0) return ret;
    if ((ret = mbedtls_x509_crt_parse_file(&m->server_cert, server_cert)) != 0) return ret;
    if ((ret = mbedtls_x509_crt_parse_file(&m->client_cert, client_cert)) != 0) return ret;
    if ((ret = mbedtls_pk_parse_keyfile(&m->server_key, server_key, NULL)) != 0) return ret;
    if ((ret = mbedtls_pk_parse_keyfile(&m->client_key, client_key, NULL)) != 0) return ret;
    return 0;
}

static void pair_init(Pair *p) {
    memset(p, 0, sizeof(*p));
    mbedtls_ssl_init(&p->client);
    mbedtls_ssl_init(&p->server);
    p->client_ep.rx = &p->s2c;
    p->client_ep.tx = &p->c2s;
    p->server_ep.rx = &p->c2s;
    p->server_ep.tx = &p->s2c;
}

static void pair_free(Pair *p) {
    mbedtls_ssl_free(&p->client);
    mbedtls_ssl_free(&p->server);
}

static int allowed_progress(int ret) {
    return ret == MBEDTLS_ERR_SSL_WANT_READ || ret == MBEDTLS_ERR_SSL_WANT_WRITE ||
           ret == MBEDTLS_ERR_SSL_CRYPTO_IN_PROGRESS;
}

static int setup_pair(Pair *p, mbedtls_ssl_config *client_conf,
                      mbedtls_ssl_config *server_conf, const char *hostname) {
    int ret;
    pair_init(p);
    if ((ret = mbedtls_ssl_setup(&p->client, client_conf)) != 0) return ret;
    if ((ret = mbedtls_ssl_setup(&p->server, server_conf)) != 0) return ret;
    if (hostname && (ret = mbedtls_ssl_set_hostname(&p->client, hostname)) != 0) return ret;
    mbedtls_ssl_set_bio(&p->client, &p->client_ep, ring_send, ring_recv, NULL);
    mbedtls_ssl_set_bio(&p->server, &p->server_ep, ring_send, ring_recv, NULL);
    return 0;
}

static int drive_handshake(Pair *p, int expect_success) {
    int client_done = 0;
    int server_done = 0;
    for (int step = 0; step < MAX_STEPS; ++step) {
        if (!client_done) {
            int ret = mbedtls_ssl_handshake(&p->client);
            if (ret == 0) client_done = 1;
            else if (!allowed_progress(ret)) return expect_success ? 0 : 1;
        }
        if (!server_done) {
            int ret = mbedtls_ssl_handshake(&p->server);
            if (ret == 0) server_done = 1;
            else if (!allowed_progress(ret)) return expect_success ? 0 : 1;
        }
        if (client_done && server_done) return expect_success ? 1 : 0;
    }
    return 0;
}

static int transfer_payload(Pair *p) {
    unsigned char *src = malloc(PAYLOAD_SIZE);
    unsigned char *dst = malloc(PAYLOAD_SIZE);
    if (!src || !dst) {
        free(src);
        free(dst);
        return 0;
    }
    for (int i = 0; i < PAYLOAD_SIZE; ++i) src[i] = (unsigned char)(i * 17u + 13u);
    size_t sent = 0;
    size_t received = 0;
    for (int step = 0; step < MAX_STEPS && received < PAYLOAD_SIZE; ++step) {
        if (sent < PAYLOAD_SIZE) {
            int ret = mbedtls_ssl_write(&p->client, src + sent, PAYLOAD_SIZE - sent);
            if (ret > 0) sent += (size_t)ret;
            else if (!allowed_progress(ret)) {
                free(src);
                free(dst);
                return 0;
            }
        }
        int ret = mbedtls_ssl_read(&p->server, dst + received, PAYLOAD_SIZE - received);
        if (ret > 0) received += (size_t)ret;
        else if (!allowed_progress(ret)) {
            free(src);
            free(dst);
            return 0;
        }
    }
    int ok = sent == PAYLOAD_SIZE && received == PAYLOAD_SIZE &&
             memcmp(src, dst, PAYLOAD_SIZE) == 0;
    free(src);
    free(dst);
    return ok;
}

static int clean_shutdown(Pair *p) {
    int client_done = 0;
    int server_done = 0;
    for (int step = 0; step < MAX_STEPS; ++step) {
        if (!client_done) {
            int ret = mbedtls_ssl_close_notify(&p->client);
            if (ret == 0) client_done = 1;
            else if (!allowed_progress(ret)) return 0;
        }
        if (!server_done) {
            int ret = mbedtls_ssl_close_notify(&p->server);
            if (ret == 0) server_done = 1;
            else if (!allowed_progress(ret)) return 0;
        }
        if (client_done && server_done) return 1;
    }
    return 0;
}

static int configure(Material *m, mbedtls_ssl_config *client_conf,
                     mbedtls_ssl_config *server_conf, int version, int mtls,
                     int trusted) {
    static const char *alpn[] = {"h2", "http/1.1", NULL};
    int ret;
    mbedtls_ssl_config_init(client_conf);
    mbedtls_ssl_config_init(server_conf);
    if ((ret = mbedtls_ssl_config_defaults(client_conf, MBEDTLS_SSL_IS_CLIENT,
                                            MBEDTLS_SSL_TRANSPORT_STREAM,
                                            MBEDTLS_SSL_PRESET_DEFAULT)) != 0) return ret;
    if ((ret = mbedtls_ssl_config_defaults(server_conf, MBEDTLS_SSL_IS_SERVER,
                                            MBEDTLS_SSL_TRANSPORT_STREAM,
                                            MBEDTLS_SSL_PRESET_DEFAULT)) != 0) return ret;
    mbedtls_ssl_conf_min_tls_version(client_conf, version);
    mbedtls_ssl_conf_max_tls_version(client_conf, version);
    mbedtls_ssl_conf_min_tls_version(server_conf, version);
    mbedtls_ssl_conf_max_tls_version(server_conf, version);
    mbedtls_ssl_conf_authmode(client_conf, MBEDTLS_SSL_VERIFY_REQUIRED);
    if (trusted) mbedtls_ssl_conf_ca_chain(client_conf, &m->ca, NULL);
    mbedtls_ssl_conf_ca_chain(server_conf, &m->ca, NULL);
    if ((ret = mbedtls_ssl_conf_own_cert(server_conf, &m->server_cert, &m->server_key)) != 0)
        return ret;
    if (mtls) {
        mbedtls_ssl_conf_authmode(server_conf, MBEDTLS_SSL_VERIFY_REQUIRED);
        if ((ret = mbedtls_ssl_conf_own_cert(client_conf, &m->client_cert, &m->client_key)) != 0)
            return ret;
    } else {
        mbedtls_ssl_conf_authmode(server_conf, MBEDTLS_SSL_VERIFY_NONE);
    }
    if ((ret = mbedtls_ssl_conf_alpn_protocols(client_conf, alpn)) != 0) return ret;
    if ((ret = mbedtls_ssl_conf_alpn_protocols(server_conf, alpn)) != 0) return ret;
    mbedtls_ssl_conf_sni(server_conf, sni_callback, NULL);
    return 0;
}

static int basic_case(Material *m, int version, int mtls) {
    mbedtls_ssl_config client_conf;
    mbedtls_ssl_config server_conf;
    Pair p;
    int ret = configure(m, &client_conf, &server_conf, version, mtls, 1);
    if (ret != 0) return 0;
    sni_seen = 0;
    ret = setup_pair(&p, &client_conf, &server_conf, "localhost");
    int ok = ret == 0 && drive_handshake(&p, 1);
    if (ok) {
        const char *alpn = mbedtls_ssl_get_alpn_protocol(&p.client);
        ok = mbedtls_ssl_get_verify_result(&p.client) == 0 && sni_seen &&
             alpn != NULL && strcmp(alpn, "h2") == 0;
    }
    if (ok) ok = transfer_payload(&p);
    if (ok) ok = clean_shutdown(&p);
    pair_free(&p);
    mbedtls_ssl_config_free(&client_conf);
    mbedtls_ssl_config_free(&server_conf);
    return ok;
}

static int alpn_no_overlap_version_case(Material *m, int version) {
    static const char *no_overlap[] = {"foo", NULL};
    mbedtls_ssl_config client_conf;
    mbedtls_ssl_config server_conf;
    Pair p;
    int ret = configure(m, &client_conf, &server_conf, version, 0, 1);
    if (ret != 0) return 0;
    ret = mbedtls_ssl_conf_alpn_protocols(&client_conf, no_overlap);
    if (ret == 0) ret = setup_pair(&p, &client_conf, &server_conf, "localhost");
    int ok = ret == 0 && drive_handshake(&p, 0);
    if (ret == 0) pair_free(&p);
    mbedtls_ssl_config_free(&client_conf);
    mbedtls_ssl_config_free(&server_conf);
    return ok;
}

static int alpn_malformed_case(Material *m) {
    static const char *empty[] = {"", NULL};
    char too_long_protocol[257];
    memset(too_long_protocol, 'x', sizeof(too_long_protocol) - 1);
    too_long_protocol[sizeof(too_long_protocol) - 1] = '\0';
    const char *too_long[] = {too_long_protocol, NULL};
    mbedtls_ssl_config client_conf;
    mbedtls_ssl_config server_conf;
    int ret = configure(
        m, &client_conf, &server_conf, MBEDTLS_SSL_VERSION_TLS1_2, 0, 1);
    if (ret != 0) return 0;
    int ok = mbedtls_ssl_conf_alpn_protocols(&client_conf, empty) != 0 &&
             mbedtls_ssl_conf_alpn_protocols(&client_conf, too_long) != 0;
    mbedtls_ssl_config_free(&client_conf);
    mbedtls_ssl_config_free(&server_conf);
    return ok;
}

static int alpn_negative_case(Material *m) {
    return alpn_no_overlap_version_case(m, MBEDTLS_SSL_VERSION_TLS1_2) &&
           alpn_no_overlap_version_case(m, MBEDTLS_SSL_VERSION_TLS1_3) &&
           alpn_malformed_case(m);
}

static int negative_case(Material *m, const char *hostname, int trusted) {
    mbedtls_ssl_config client_conf;
    mbedtls_ssl_config server_conf;
    Pair p;
    int ret = configure(m, &client_conf, &server_conf,
                        MBEDTLS_SSL_VERSION_TLS1_2, 0, trusted);
    if (ret != 0) return 0;
    ret = setup_pair(&p, &client_conf, &server_conf, hostname);
    int ok = ret == 0 && drive_handshake(&p, 0);
    pair_free(&p);
    mbedtls_ssl_config_free(&client_conf);
    mbedtls_ssl_config_free(&server_conf);
    return ok;
}

static int external_trust_version_case(Material *m, int version) {
    mbedtls_ssl_config client_conf;
    mbedtls_ssl_config server_conf;
    Pair accepted;
    int ret = configure(m, &client_conf, &server_conf, version, 0, 0);
    if (ret != 0) return 0;
    mbedtls_ssl_conf_ca_chain(&client_conf, &m->client_cert, NULL);

    Pair provider_rejected;
    ret = setup_pair(&provider_rejected, &client_conf, &server_conf, "localhost");
    int ok = ret == 0 && drive_handshake(&provider_rejected, 0);
    pair_free(&provider_rejected);

    mbedtls_ssl_conf_verify(&client_conf, external_trust_callback, NULL);
    external_trust_decision = 1;
    unsigned int calls_before = external_trust_calls;
    ret = setup_pair(&accepted, &client_conf, &server_conf, "localhost");
    ok = ok && ret == 0 && drive_handshake(&accepted, 1) &&
         external_trust_calls > calls_before;
    pair_free(&accepted);

    external_trust_decision = 0;
    calls_before = external_trust_calls;
    Pair rejected;
    ret = setup_pair(&rejected, &client_conf, &server_conf, "localhost");
    ok = ok && ret == 0 && drive_handshake(&rejected, 0) &&
         external_trust_calls > calls_before;
    pair_free(&rejected);
    mbedtls_ssl_config_free(&client_conf);
    mbedtls_ssl_config_free(&server_conf);
    return ok;
}

static int external_trust_case(Material *m) {
    external_trust_calls = 0;
    return external_trust_version_case(m, MBEDTLS_SSL_VERSION_TLS1_2) &&
           external_trust_version_case(m, MBEDTLS_SSL_VERSION_TLS1_3) &&
           external_trust_calls >= 4;
}

static int cancellation_case(Material *m) {
    mbedtls_ssl_config conf;
    mbedtls_ssl_context ssl;
    Ring rx = {0};
    Ring tx = {0};
    Endpoint ep = {&rx, &tx};
    mbedtls_ssl_config_init(&conf);
    mbedtls_ssl_init(&ssl);
    int ret = mbedtls_ssl_config_defaults(&conf, MBEDTLS_SSL_IS_CLIENT,
                                           MBEDTLS_SSL_TRANSPORT_STREAM,
                                           MBEDTLS_SSL_PRESET_DEFAULT);
    if (ret == 0) {
        mbedtls_ssl_conf_authmode(&conf, MBEDTLS_SSL_VERIFY_REQUIRED);
        mbedtls_ssl_conf_ca_chain(&conf, &m->ca, NULL);
        ret = mbedtls_ssl_setup(&ssl, &conf);
    }
    if (ret == 0) ret = mbedtls_ssl_set_hostname(&ssl, "localhost");
    if (ret == 0) {
        mbedtls_ssl_set_bio(&ssl, &ep, ring_send, ring_recv, NULL);
        ret = mbedtls_ssl_handshake(&ssl);
    }
    int ok = allowed_progress(ret);
    mbedtls_ssl_free(&ssl);
    mbedtls_ssl_config_free(&conf);
    return ok;
}

static int truncation_case(Material *m) {
    mbedtls_ssl_config client_conf;
    mbedtls_ssl_config server_conf;
    Pair p;
    int ret = configure(m, &client_conf, &server_conf,
                        MBEDTLS_SSL_VERSION_TLS1_2, 0, 1);
    if (ret != 0) return 0;
    ret = setup_pair(&p, &client_conf, &server_conf, "localhost");
    int ok = ret == 0 && drive_handshake(&p, 1);
    if (ok) {
        p.c2s.closed = 1;
        unsigned char byte;
        ret = mbedtls_ssl_read(&p.server, &byte, 1);
        ok = ret != MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY;
    }
    pair_free(&p);
    mbedtls_ssl_config_free(&client_conf);
    mbedtls_ssl_config_free(&server_conf);
    return ok;
}

int main(int argc, char **argv) {
    if (argc != 6) {
        fprintf(stderr, "usage: %s SERVER_CERT SERVER_KEY CA CLIENT_CERT CLIENT_KEY\n", argv[0]);
        return 2;
    }
    if (psa_crypto_init() != PSA_SUCCESS) return 2;
    Material m;
    material_init(&m);
    int ret = load_material(&m, argv[1], argv[2], argv[3], argv[4], argv[5]);
    if (ret != 0) {
        char error[256];
        mbedtls_strerror(ret, error, sizeof(error));
        fprintf(stderr, "material load failed: %s (%d)\n", error, ret);
        material_free(&m);
        mbedtls_psa_crypto_free();
        return 2;
    }

    int tls12 = basic_case(&m, MBEDTLS_SSL_VERSION_TLS1_2, 0);
    int tls13 = basic_case(&m, MBEDTLS_SSL_VERSION_TLS1_3, 0);
    int alpn_negative = alpn_negative_case(&m);
    int mtls = basic_case(&m, MBEDTLS_SSL_VERSION_TLS1_2, 1);
    int external_trust = external_trust_case(&m);
    int wrong_host = negative_case(&m, "not-localhost", 1);
    int untrusted = negative_case(&m, "localhost", 0);
    int trunc = truncation_case(&m);
    int cancel = cancellation_case(&m);
    int cleanup = 1;
    for (int i = 0; i < CLEANUP_CYCLES && cleanup; ++i)
        cleanup = basic_case(&m, MBEDTLS_SSL_VERSION_TLS1_2, 0);

    printf("CAP tls12=%s\n", tls12 ? "PASS" : "FAIL");
    printf("CAP tls13=%s\n", tls13 ? "PASS" : "FAIL");
    printf("CAP sni_hostname_alpn=%s\n",
           (tls12 && tls13 && alpn_negative) ? "PASS" : "FAIL");
    printf("CAP custom_ca=%s\n", (tls12 && tls13) ? "PASS" : "FAIL");
    printf("CAP external_trust=%s\n", external_trust ? "PASS" : "FAIL");
    printf("CAP partial_io_backpressure=%s\n", (tls12 && tls13) ? "PASS" : "FAIL");
    printf("CAP mtls=%s\n", mtls ? "PASS" : "FAIL");
    printf("CAP session_resumption=BLOCKED\n");
    printf("CAP negative_hostname=%s\n", wrong_host ? "PASS" : "FAIL");
    printf("CAP negative_untrusted_ca=%s\n", untrusted ? "PASS" : "FAIL");
    printf("CAP close_notify=%s\n", (tls12 && tls13) ? "PASS" : "FAIL");
    printf("CAP truncation=%s\n", trunc ? "PASS" : "FAIL");
    printf("CAP caller_cancellation=%s\n", cancel ? "PASS" : "FAIL");
    printf("CAP external_signer=BLOCKED\n");
    printf("CAP repeated_cleanup=%s\n", cleanup ? "PASS" : "FAIL");
    printf("METRIC repeated_cleanup_cycles=%d\n", CLEANUP_CYCLES);
    printf("METRIC external_trust_calls=%u\n", external_trust_calls);
    printf("METRIC alpn_no_overlap_handshakes=%d\n", alpn_negative ? 2 : 0);
    printf("METRIC alpn_malformed_inputs_rejected=%d\n", alpn_negative ? 2 : 0);

    material_free(&m);
    mbedtls_psa_crypto_free();
    return (tls12 && tls13 && alpn_negative && mtls && external_trust && wrong_host && untrusted && trunc && cancel && cleanup) ? 0 : 1;
}
