#include <openssl/ssl.h>
#include <openssl/err.h>
#include <openssl/x509_vfy.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX_STEPS 200000
#define BIO_CAPACITY 4096
#define PAYLOAD_SIZE 32768

static const unsigned char ALPN_WIRE[] = {2, 'h', '2', 8, 'h','t','t','p','/','1','.','1'};
static int sni_seen = 0;
static int alpn_seen = 0;

static void fail(const char *what) {
    fprintf(stderr, "FAIL %s\n", what);
    ERR_print_errors_fp(stderr);
    exit(2);
}

static int sni_cb(SSL *ssl, int *alert, void *arg) {
    (void)alert;
    (void)arg;
    const char *name = SSL_get_servername(ssl, TLSEXT_NAMETYPE_host_name);
    if (name != NULL && strcmp(name, "localhost") == 0) sni_seen = 1;
    return SSL_TLSEXT_ERR_OK;
}

static int alpn_cb(SSL *ssl, const unsigned char **out, unsigned char *outlen,
                   const unsigned char *in, unsigned int inlen, void *arg) {
    (void)ssl;
    (void)arg;
    static const unsigned char h2[] = {2, 'h', '2'};
    if (SSL_select_next_proto((unsigned char **)out, outlen,
                              h2, (unsigned int)sizeof(h2), in, inlen)
        == OPENSSL_NPN_NEGOTIATED) {
        alpn_seen = 1;
        return SSL_TLSEXT_ERR_OK;
    }
    return SSL_TLSEXT_ERR_NOACK;
}

static SSL_CTX *make_server_ctx(const char *cert, const char *key, const char *ca,
                                int version, int require_client) {
    SSL_CTX *ctx = SSL_CTX_new(TLS_method());
    if (!ctx) fail("SSL_CTX_new server");
    if (!SSL_CTX_set_min_proto_version(ctx, version) ||
        !SSL_CTX_set_max_proto_version(ctx, version)) fail("server protocol version");
    if (SSL_CTX_use_certificate_chain_file(ctx, cert) != 1) fail("server cert");
    if (SSL_CTX_use_PrivateKey_file(ctx, key, SSL_FILETYPE_PEM) != 1) fail("server key");
    if (SSL_CTX_check_private_key(ctx) != 1) fail("server key check");
    if (ca && SSL_CTX_load_verify_locations(ctx, ca, NULL) != 1) fail("server CA");
    if (require_client) {
        SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER | SSL_VERIFY_FAIL_IF_NO_PEER_CERT, NULL);
    }
    SSL_CTX_set_tlsext_servername_callback(ctx, sni_cb);
    SSL_CTX_set_alpn_select_cb(ctx, alpn_cb, NULL);
    SSL_CTX_set_session_cache_mode(ctx, SSL_SESS_CACHE_SERVER);
    {
        static const unsigned char sid_ctx[] = "wirestack-poc";
        if (SSL_CTX_set_session_id_context(ctx, sid_ctx, sizeof(sid_ctx) - 1) != 1)
            fail("session id context");
    }
    return ctx;
}

static SSL_CTX *make_client_ctx(const char *ca, const char *cert, const char *key,
                                int version, int verify) {
    SSL_CTX *ctx = SSL_CTX_new(TLS_method());
    if (!ctx) fail("SSL_CTX_new client");
    if (!SSL_CTX_set_min_proto_version(ctx, version) ||
        !SSL_CTX_set_max_proto_version(ctx, version)) fail("client protocol version");
    if (verify) {
        SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, NULL);
        if (ca && SSL_CTX_load_verify_locations(ctx, ca, NULL) != 1) fail("client CA");
    } else {
        SSL_CTX_set_verify(ctx, SSL_VERIFY_NONE, NULL);
    }
    if (cert) {
        if (SSL_CTX_use_certificate_chain_file(ctx, cert) != 1) fail("client cert");
        if (SSL_CTX_use_PrivateKey_file(ctx, key, SSL_FILETYPE_PEM) != 1) fail("client key");
        if (SSL_CTX_check_private_key(ctx) != 1) fail("client key check");
    }
    SSL_CTX_set_session_cache_mode(ctx, SSL_SESS_CACHE_CLIENT);
    return ctx;
}

typedef struct {
    SSL *client;
    SSL *server;
} Pair;

static Pair new_pair(SSL_CTX *client_ctx, SSL_CTX *server_ctx, const char *hostname,
                     SSL_SESSION *session) {
    Pair p = {0};
    BIO *cbio = NULL;
    BIO *sbio = NULL;
    p.client = SSL_new(client_ctx);
    p.server = SSL_new(server_ctx);
    if (!p.client || !p.server) fail("SSL_new");
    if (BIO_new_bio_pair(&cbio, BIO_CAPACITY, &sbio, BIO_CAPACITY) != 1)
        fail("BIO_new_bio_pair");
    SSL_set_bio(p.client, cbio, cbio);
    SSL_set_bio(p.server, sbio, sbio);
    SSL_set_connect_state(p.client);
    SSL_set_accept_state(p.server);
    SSL_set_mode(p.client, SSL_MODE_ENABLE_PARTIAL_WRITE | SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER);
    SSL_set_mode(p.server, SSL_MODE_ENABLE_PARTIAL_WRITE | SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER);
    if (hostname) {
        if (SSL_set_tlsext_host_name(p.client, hostname) != 1) fail("set SNI");
        X509_VERIFY_PARAM *param = SSL_get0_param(p.client);
        if (!param || X509_VERIFY_PARAM_set1_host(param, hostname, 0) != 1)
            fail("set hostname verification");
    }
    if (SSL_set_alpn_protos(p.client, ALPN_WIRE, sizeof(ALPN_WIRE)) != 0)
        fail("set client ALPN");
    if (session && SSL_set_session(p.client, session) != 1) fail("set session");
    return p;
}

static void free_pair(Pair *p) {
    if (p->client) SSL_free(p->client);
    if (p->server) SSL_free(p->server);
    p->client = p->server = NULL;
}

static int drive_handshake(Pair *p, int expect_success, int max_steps) {
    int cd = 0;
    int sd = 0;
    for (int step = 0; step < max_steps; ++step) {
        if (!cd) {
            int r = SSL_do_handshake(p->client);
            if (r == 1) cd = 1;
            else {
                int e = SSL_get_error(p->client, r);
                if (e != SSL_ERROR_WANT_READ && e != SSL_ERROR_WANT_WRITE)
                    return expect_success ? 0 : 1;
            }
        }
        if (!sd) {
            int r = SSL_do_handshake(p->server);
            if (r == 1) sd = 1;
            else {
                int e = SSL_get_error(p->server, r);
                if (e != SSL_ERROR_WANT_READ && e != SSL_ERROR_WANT_WRITE)
                    return expect_success ? 0 : 1;
            }
        }
        if (cd && sd) return expect_success ? 1 : 0;
    }
    return 0;
}

static int verify_negotiation(Pair *p, int version) {
    const unsigned char *alpn = NULL;
    unsigned int alpn_len = 0;
    SSL_get0_alpn_selected(p->client, &alpn, &alpn_len);
    if (SSL_version(p->client) != version || SSL_version(p->server) != version) return 0;
    if (SSL_get_verify_result(p->client) != X509_V_OK) return 0;
    if (alpn_len != 2 || memcmp(alpn, "h2", 2) != 0) return 0;
    return sni_seen && alpn_seen;
}

static int transfer_payload(Pair *p) {
    unsigned char *src = malloc(PAYLOAD_SIZE);
    unsigned char *dst = malloc(PAYLOAD_SIZE);
    if (!src || !dst) fail("malloc payload");
    for (int i = 0; i < PAYLOAD_SIZE; ++i) src[i] = (unsigned char)(i * 31u + 7u);
    size_t sent = 0;
    size_t received = 0;
    for (int step = 0; step < MAX_STEPS && received < PAYLOAD_SIZE; ++step) {
        if (sent < PAYLOAD_SIZE) {
            int r = SSL_write(p->client, src + sent, (int)(PAYLOAD_SIZE - sent));
            if (r > 0) sent += (size_t)r;
            else {
                int e = SSL_get_error(p->client, r);
                if (e != SSL_ERROR_WANT_READ && e != SSL_ERROR_WANT_WRITE) {
                    free(src);
                    free(dst);
                    return 0;
                }
            }
        }
        int r = SSL_read(p->server, dst + received, (int)(PAYLOAD_SIZE - received));
        if (r > 0) received += (size_t)r;
        else {
            int e = SSL_get_error(p->server, r);
            if (e != SSL_ERROR_WANT_READ && e != SSL_ERROR_WANT_WRITE) {
                free(src);
                free(dst);
                return 0;
            }
        }
    }
    int ok = sent == PAYLOAD_SIZE && received == PAYLOAD_SIZE &&
             memcmp(src, dst, PAYLOAD_SIZE) == 0;
    free(src);
    free(dst);
    return ok;
}

static int clean_shutdown(Pair *p) {
    int cd = 0;
    int sd = 0;
    for (int step = 0; step < MAX_STEPS; ++step) {
        if (!cd) {
            int r = SSL_shutdown(p->client);
            if (r == 1) cd = 1;
            else if (r < 0) {
                int e = SSL_get_error(p->client, r);
                if (e != SSL_ERROR_WANT_READ && e != SSL_ERROR_WANT_WRITE) return 0;
            }
        }
        if (!sd) {
            int r = SSL_shutdown(p->server);
            if (r == 1) sd = 1;
            else if (r < 0) {
                int e = SSL_get_error(p->server, r);
                if (e != SSL_ERROR_WANT_READ && e != SSL_ERROR_WANT_WRITE) return 0;
            }
        }
        if (cd && sd) return 1;
    }
    return 0;
}

static int basic_case(const char *server_cert, const char *server_key, const char *ca,
                      const char *client_cert, const char *client_key, int version,
                      int mtls, int do_session) {
    sni_seen = alpn_seen = 0;
    SSL_CTX *server_ctx = make_server_ctx(server_cert, server_key, ca, version, mtls);
    SSL_CTX *client_ctx = make_client_ctx(ca, mtls ? client_cert : NULL,
                                         mtls ? client_key : NULL, version, 1);
    Pair p = new_pair(client_ctx, server_ctx, "localhost", NULL);
    int ok = drive_handshake(&p, 1, MAX_STEPS) && verify_negotiation(&p, version) &&
             transfer_payload(&p);
    SSL_SESSION *session = NULL;
    if (ok && do_session) session = SSL_get1_session(p.client);
    if (ok) ok = clean_shutdown(&p);
    free_pair(&p);
    if (ok && do_session) {
        Pair p2 = new_pair(client_ctx, server_ctx, "localhost", session);
        ok = drive_handshake(&p2, 1, MAX_STEPS) && SSL_session_reused(p2.client) == 1;
        if (ok) ok = clean_shutdown(&p2);
        free_pair(&p2);
    }
    if (session) SSL_SESSION_free(session);
    SSL_CTX_free(client_ctx);
    SSL_CTX_free(server_ctx);
    return ok;
}

static int negative_case(const char *server_cert, const char *server_key, const char *ca,
                         const char *hostname, int trust_ca) {
    SSL_CTX *server_ctx = make_server_ctx(server_cert, server_key, ca, TLS1_2_VERSION, 0);
    SSL_CTX *client_ctx = make_client_ctx(trust_ca ? ca : NULL, NULL, NULL,
                                         TLS1_2_VERSION, 1);
    Pair p = new_pair(client_ctx, server_ctx, hostname, NULL);
    int ok = drive_handshake(&p, 0, MAX_STEPS);
    free_pair(&p);
    SSL_CTX_free(client_ctx);
    SSL_CTX_free(server_ctx);
    ERR_clear_error();
    return ok;
}

static int truncation_case(const char *server_cert, const char *server_key, const char *ca) {
    SSL_CTX *server_ctx = make_server_ctx(server_cert, server_key, ca, TLS1_2_VERSION, 0);
    SSL_CTX *client_ctx = make_client_ctx(ca, NULL, NULL, TLS1_2_VERSION, 1);
    Pair p = new_pair(client_ctx, server_ctx, "localhost", NULL);
    int ok = drive_handshake(&p, 1, MAX_STEPS);
    if (ok) {
        SSL_free(p.client);
        p.client = NULL;
        unsigned char byte;
        int r = SSL_read(p.server, &byte, 1);
        int e = SSL_get_error(p.server, r);
        ok = r <= 0 && e != SSL_ERROR_ZERO_RETURN;
    }
    free_pair(&p);
    SSL_CTX_free(client_ctx);
    SSL_CTX_free(server_ctx);
    ERR_clear_error();
    return ok;
}

static int cancellation_case(const char *ca) {
    SSL_CTX *client_ctx = make_client_ctx(ca, NULL, NULL, TLS1_2_VERSION, 1);
    SSL *client = SSL_new(client_ctx);
    BIO *in = BIO_new(BIO_s_mem());
    BIO *out = BIO_new(BIO_s_mem());
    if (!client || !in || !out) fail("cancel setup");
    SSL_set_bio(client, in, out);
    SSL_set_connect_state(client);
    int observed_want = 0;
    for (int i = 0; i < 8; ++i) {
        int r = SSL_do_handshake(client);
        if (r == 1) break;
        int e = SSL_get_error(client, r);
        if (e == SSL_ERROR_WANT_READ || e == SSL_ERROR_WANT_WRITE) observed_want = 1;
        else break;
    }
    SSL_free(client);
    SSL_CTX_free(client_ctx);
    ERR_clear_error();
    return observed_want;
}

int main(int argc, char **argv) {
    if (argc != 6) {
        fprintf(stderr, "usage: %s SERVER_CERT SERVER_KEY CA CLIENT_CERT CLIENT_KEY\n", argv[0]);
        return 2;
    }
    OPENSSL_init_ssl(0, NULL);
    const char *server_cert = argv[1];
    const char *server_key = argv[2];
    const char *ca = argv[3];
    const char *client_cert = argv[4];
    const char *client_key = argv[5];

    int tls12 = basic_case(server_cert, server_key, ca, client_cert, client_key,
                           TLS1_2_VERSION, 0, 1);
    int tls13 = basic_case(server_cert, server_key, ca, client_cert, client_key,
                           TLS1_3_VERSION, 0, 0);
    int mtls = basic_case(server_cert, server_key, ca, client_cert, client_key,
                          TLS1_2_VERSION, 1, 0);
    int wrong_host = negative_case(server_cert, server_key, ca, "not-localhost", 1);
    int untrusted = negative_case(server_cert, server_key, ca, "localhost", 0);
    int trunc = truncation_case(server_cert, server_key, ca);
    int cancel = cancellation_case(ca);
    int cleanup = 1;
    for (int i = 0; i < 16 && cleanup; ++i) {
        cleanup = basic_case(server_cert, server_key, ca, client_cert, client_key,
                             TLS1_2_VERSION, 0, 0);
    }

    printf("CAP tls12=%s\n", tls12 ? "PASS" : "FAIL");
    printf("CAP tls13=%s\n", tls13 ? "PASS" : "FAIL");
    printf("CAP sni_hostname_alpn=%s\n", (tls12 && tls13) ? "PASS" : "FAIL");
    printf("CAP custom_ca=%s\n", (tls12 && tls13) ? "PASS" : "FAIL");
    printf("CAP partial_io_backpressure=%s\n", (tls12 && tls13) ? "PASS" : "FAIL");
    printf("CAP mtls=%s\n", mtls ? "PASS" : "FAIL");
    printf("CAP session_resumption=%s\n", tls12 ? "PASS" : "FAIL");
    printf("CAP negative_hostname=%s\n", wrong_host ? "PASS" : "FAIL");
    printf("CAP negative_untrusted_ca=%s\n", untrusted ? "PASS" : "FAIL");
    printf("CAP close_notify=%s\n", (tls12 && tls13) ? "PASS" : "FAIL");
    printf("CAP truncation=%s\n", trunc ? "PASS" : "FAIL");
    printf("CAP caller_cancellation=%s\n", cancel ? "PASS" : "FAIL");
    printf("CAP external_signer=BLOCKED\n");
    printf("CAP repeated_cleanup=%s\n", cleanup ? "PASS" : "FAIL");

    return (tls12 && tls13 && mtls && wrong_host && untrusted && trunc && cancel && cleanup) ? 0 : 1;
}
