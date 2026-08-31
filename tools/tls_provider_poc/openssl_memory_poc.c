#include <openssl/ssl.h>
#include <openssl/err.h>
#include <openssl/pem.h>
#include <openssl/rsa.h>
#include <openssl/x509_vfy.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX_STEPS 200000
#define BIO_CAPACITY 4096
#define PAYLOAD_SIZE 32768
#ifndef CLEANUP_CYCLES
#define CLEANUP_CYCLES 10000
#endif
#ifndef FAILURE_CLEANUP_CYCLES
#define FAILURE_CLEANUP_CYCLES 0
#endif

static const unsigned char ALPN_WIRE[] = {2, 'h', '2', 8, 'h','t','t','p','/','1','.','1'};
static int sni_seen = 0;
static int alpn_seen = 0;
static int external_trust_decision = 0;
static unsigned int external_trust_calls = 0;
static SSL_SESSION *captured_session = NULL;
static unsigned int session_resumption_tls12_handshakes = 0;
static unsigned int session_resumption_tls13_handshakes = 0;

#if defined(OPENSSL_IS_AWSLC)
static enum ssl_verify_result_t external_trust_callback(
    SSL *ssl, uint8_t *out_alert) {
    (void)ssl;
    external_trust_calls++;
    if (external_trust_decision) return ssl_verify_ok;
    *out_alert = SSL_AD_CERTIFICATE_UNKNOWN;
    return ssl_verify_invalid;
}
#else
static int external_trust_callback(X509_STORE_CTX *store, void *opaque) {
    (void)opaque;
    external_trust_calls++;
    if (external_trust_decision) {
        X509_STORE_CTX_set_error(store, X509_V_OK);
        return 1;
    }
    X509_STORE_CTX_set_error(store, X509_V_ERR_CERT_REJECTED);
    return 0;
}
#endif

static int capture_session_callback(SSL *ssl, SSL_SESSION *session) {
    (void)ssl;
    if (captured_session != NULL) SSL_SESSION_free(captured_session);
    if (SSL_SESSION_up_ref(session) != 1) {
        captured_session = NULL;
        return 0;
    }
    captured_session = session;
    return 1;
}

#if defined(OPENSSL_IS_AWSLC)
static EVP_PKEY *external_signer_key = NULL;
static unsigned int external_signer_calls = 0;

static enum ssl_private_key_result_t external_sign(
    SSL *ssl, uint8_t *out, size_t *out_len, size_t max_out,
    uint16_t signature_algorithm, const uint8_t *in, size_t in_len) {
    (void)ssl;
    if (external_signer_key == NULL) return ssl_private_key_failure;

    const EVP_MD *digest = SSL_get_signature_algorithm_digest(signature_algorithm);
    if (digest == NULL) return ssl_private_key_failure;

    EVP_MD_CTX *digest_ctx = EVP_MD_CTX_new();
    EVP_PKEY_CTX *key_ctx = NULL;
    if (digest_ctx == NULL ||
        EVP_DigestSignInit(digest_ctx, &key_ctx, digest, NULL,
                           external_signer_key) != 1) {
        EVP_MD_CTX_free(digest_ctx);
        return ssl_private_key_failure;
    }
    if (SSL_is_signature_algorithm_rsa_pss(signature_algorithm) &&
        (EVP_PKEY_CTX_set_rsa_padding(key_ctx, RSA_PKCS1_PSS_PADDING) <= 0 ||
         EVP_PKEY_CTX_set_rsa_pss_saltlen(key_ctx, RSA_PSS_SALTLEN_DIGEST) <= 0)) {
        EVP_MD_CTX_free(digest_ctx);
        return ssl_private_key_failure;
    }

    size_t produced = max_out;
    int ok = EVP_DigestSign(digest_ctx, out, &produced, in, in_len) == 1 &&
             produced <= max_out;
    EVP_MD_CTX_free(digest_ctx);
    if (!ok) return ssl_private_key_failure;
    *out_len = produced;
    external_signer_calls++;
    return ssl_private_key_success;
}

static const SSL_PRIVATE_KEY_METHOD EXTERNAL_KEY_METHOD = {
    external_sign,
    NULL,
    NULL,
};

static EVP_PKEY *load_external_signer_key(const char *path) {
    FILE *stream = fopen(path, "r");
    if (stream == NULL) return NULL;
    EVP_PKEY *key = PEM_read_PrivateKey(stream, NULL, NULL, NULL);
    fclose(stream);
    return key;
}
#endif

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
                                int version, int require_client, int use_external_signer) {
    SSL_CTX *ctx = SSL_CTX_new(TLS_method());
    if (!ctx) fail("SSL_CTX_new server");
    if (!SSL_CTX_set_min_proto_version(ctx, version) ||
        !SSL_CTX_set_max_proto_version(ctx, version)) fail("server protocol version");
    if (SSL_CTX_use_certificate_chain_file(ctx, cert) != 1) fail("server cert");
    if (use_external_signer) {
#if defined(OPENSSL_IS_AWSLC)
        static const uint16_t signing_algorithms[] = {
            SSL_SIGN_RSA_PSS_RSAE_SHA256,
            SSL_SIGN_RSA_PSS_RSAE_SHA384,
            SSL_SIGN_RSA_PSS_RSAE_SHA512,
            SSL_SIGN_RSA_PKCS1_SHA256,
            SSL_SIGN_RSA_PKCS1_SHA384,
            SSL_SIGN_RSA_PKCS1_SHA512,
        };
        if (external_signer_key == NULL) fail("external signer key missing");
        SSL_CTX_set_private_key_method(ctx, &EXTERNAL_KEY_METHOD);
        if (SSL_CTX_set_signing_algorithm_prefs(
                ctx, signing_algorithms,
                sizeof(signing_algorithms) / sizeof(signing_algorithms[0])) != 1)
            fail("external signer algorithms");
#else
        fail("external signer unavailable");
#endif
    } else {
        if (SSL_CTX_use_PrivateKey_file(ctx, key, SSL_FILETYPE_PEM) != 1)
            fail("server key");
        if (SSL_CTX_check_private_key(ctx) != 1) fail("server key check");
    }
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

static void configure_external_trust(SSL_CTX *ctx) {
#if defined(OPENSSL_IS_AWSLC)
    SSL_CTX_set_custom_verify(ctx, SSL_VERIFY_PEER, external_trust_callback);
#else
    SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, NULL);
    SSL_CTX_set_cert_verify_callback(ctx, external_trust_callback, NULL);
#endif
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
                      int mtls) {
    sni_seen = alpn_seen = 0;
    SSL_CTX *server_ctx = make_server_ctx(server_cert, server_key, ca, version, mtls, 0);
    SSL_CTX *client_ctx = make_client_ctx(ca, mtls ? client_cert : NULL,
                                         mtls ? client_key : NULL, version, 1);
    Pair p = new_pair(client_ctx, server_ctx, "localhost", NULL);
    int ok = drive_handshake(&p, 1, MAX_STEPS) && verify_negotiation(&p, version) &&
             transfer_payload(&p);
    if (ok) ok = clean_shutdown(&p);
    free_pair(&p);
    SSL_CTX_free(client_ctx);
    SSL_CTX_free(server_ctx);
    return ok;
}

static SSL_SESSION *session_after_handshake(Pair *p, SSL_CTX *client_ctx) {
    for (int step = 0; step < MAX_STEPS && captured_session == NULL; ++step) {
        unsigned char byte = 0;
        int ret = SSL_read(p->client, &byte, 1);
        if (ret > 0) return NULL;
        int error = SSL_get_error(p->client, ret);
        if (error != SSL_ERROR_WANT_READ && error != SSL_ERROR_WANT_WRITE)
            return NULL;
    }
    SSL_SESSION *session = captured_session;
    captured_session = NULL;
    SSL_CTX_sess_set_new_cb(client_ctx, NULL);
    return session;
}

static int session_resumption_version_case(
    const char *server_cert, const char *server_key, const char *ca, int version) {
    SSL_CTX *server_ctx = make_server_ctx(
        server_cert, server_key, ca, version, 0, 0);
    SSL_CTX *client_ctx = make_client_ctx(ca, NULL, NULL, version, 1);
    if (captured_session != NULL) SSL_SESSION_free(captured_session);
    captured_session = NULL;
    SSL_CTX_sess_set_new_cb(client_ctx, capture_session_callback);
    Pair first = new_pair(client_ctx, server_ctx, "localhost", NULL);
    int ok = drive_handshake(&first, 1, MAX_STEPS) &&
             verify_negotiation(&first, version) &&
             transfer_payload(&first);
    SSL_SESSION *session = ok ? session_after_handshake(&first, client_ctx) : NULL;
    ok = ok && session != NULL;
    if (ok) ok = clean_shutdown(&first);
    free_pair(&first);

    if (ok) {
        Pair resumed = new_pair(client_ctx, server_ctx, "localhost", session);
        ok = drive_handshake(&resumed, 1, MAX_STEPS) &&
             SSL_session_reused(resumed.client) == 1 &&
             SSL_session_reused(resumed.server) == 1 &&
             verify_negotiation(&resumed, version) &&
             transfer_payload(&resumed);
        if (ok) ok = clean_shutdown(&resumed);
        free_pair(&resumed);
    }
    if (session) SSL_SESSION_free(session);
    SSL_CTX_free(client_ctx);
    SSL_CTX_free(server_ctx);
    return ok;
}

static int session_resumption_case(const char *server_cert, const char *server_key,
                                   const char *ca) {
    int tls12 = session_resumption_version_case(
        server_cert, server_key, ca, TLS1_2_VERSION);
    int tls13 = session_resumption_version_case(
        server_cert, server_key, ca, TLS1_3_VERSION);
    session_resumption_tls12_handshakes = tls12 ? 2u : 0u;
    session_resumption_tls13_handshakes = tls13 ? 2u : 0u;
    return tls12 && tls13;
}

static int external_trust_version_case(
    const char *server_cert, const char *server_key, int version) {
    SSL_CTX *server_ctx = make_server_ctx(
        server_cert, server_key, NULL, version, 0, 0);
    SSL_CTX *client_ctx = make_client_ctx(NULL, NULL, NULL, version, 0);
    configure_external_trust(client_ctx);
    external_trust_decision = 1;
    unsigned int calls_before = external_trust_calls;
    Pair accepted = new_pair(client_ctx, server_ctx, "localhost", NULL);
    int ok = drive_handshake(&accepted, 1, MAX_STEPS) &&
             external_trust_calls > calls_before;
    free_pair(&accepted);

    external_trust_decision = 0;
    calls_before = external_trust_calls;
    Pair rejected = new_pair(client_ctx, server_ctx, "localhost", NULL);
    ok = ok && drive_handshake(&rejected, 0, MAX_STEPS) &&
         external_trust_calls > calls_before;
    free_pair(&rejected);
    SSL_CTX_free(client_ctx);
    SSL_CTX_free(server_ctx);
    ERR_clear_error();
    return ok;
}

static int external_trust_case(const char *server_cert, const char *server_key) {
    external_trust_calls = 0;
    return external_trust_version_case(server_cert, server_key, TLS1_2_VERSION) &&
           external_trust_version_case(server_cert, server_key, TLS1_3_VERSION) &&
           external_trust_calls >= 4;
}

static int negative_case(const char *server_cert, const char *server_key, const char *ca,
                         const char *hostname, int trust_ca) {
    SSL_CTX *server_ctx = make_server_ctx(
        server_cert, server_key, ca, TLS1_2_VERSION, 0, 0);
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
    SSL_CTX *server_ctx = make_server_ctx(
        server_cert, server_key, ca, TLS1_2_VERSION, 0, 0);
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

#if defined(OPENSSL_IS_AWSLC)
static int external_signer_version_case(const char *server_cert, const char *server_key,
                                        const char *ca, int version) {
    SSL_CTX *server_ctx = make_server_ctx(
        server_cert, server_key, ca, version, 0, 1);
    SSL_CTX *client_ctx = make_client_ctx(ca, NULL, NULL, version, 1);
    Pair p = new_pair(client_ctx, server_ctx, "localhost", NULL);
    unsigned int calls_before = external_signer_calls;
    int ok = drive_handshake(&p, 1, MAX_STEPS) &&
             verify_negotiation(&p, version) && transfer_payload(&p) &&
             external_signer_calls > calls_before;
    if (ok) ok = clean_shutdown(&p);
    free_pair(&p);
    SSL_CTX_free(client_ctx);
    SSL_CTX_free(server_ctx);
    return ok;
}

static int external_signer_case(const char *server_cert, const char *server_key,
                                const char *ca) {
    external_signer_key = load_external_signer_key(server_key);
    external_signer_calls = 0;
    if (external_signer_key == NULL) return 0;
    int ok = external_signer_version_case(
                 server_cert, server_key, ca, TLS1_2_VERSION) &&
             external_signer_version_case(
                 server_cert, server_key, ca, TLS1_3_VERSION) &&
             external_signer_calls >= 2;
    EVP_PKEY_free(external_signer_key);
    external_signer_key = NULL;
    return ok;
}
#endif

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
                           TLS1_2_VERSION, 0);
    int tls13 = basic_case(server_cert, server_key, ca, client_cert, client_key,
                           TLS1_3_VERSION, 0);
    int mtls = basic_case(server_cert, server_key, ca, client_cert, client_key,
                          TLS1_2_VERSION, 1);
    int session_resumption = session_resumption_case(server_cert, server_key, ca);
    int external_trust = external_trust_case(server_cert, server_key);
    int wrong_host = negative_case(server_cert, server_key, ca, "not-localhost", 1);
    int untrusted = negative_case(server_cert, server_key, ca, "localhost", 0);
    int trunc = truncation_case(server_cert, server_key, ca);
    int cancel = cancellation_case(ca);
#if defined(OPENSSL_IS_AWSLC)
    int external_signer = external_signer_case(server_cert, server_key, ca);
#endif
    int cleanup = 1;
    for (int i = 0; i < CLEANUP_CYCLES && cleanup; ++i) {
        cleanup = basic_case(server_cert, server_key, ca, client_cert, client_key,
                             TLS1_2_VERSION, 0);
    }
    int failure_cleanup = 1;
    for (int i = 0; i < FAILURE_CLEANUP_CYCLES && failure_cleanup; ++i) {
        failure_cleanup = negative_case(
            server_cert, server_key, ca, "not-localhost", 1);
    }

    printf("CAP tls12=%s\n", tls12 ? "PASS" : "FAIL");
    printf("CAP tls13=%s\n", tls13 ? "PASS" : "FAIL");
    printf("CAP sni_hostname_alpn=%s\n", (tls12 && tls13) ? "PASS" : "FAIL");
    printf("CAP custom_ca=%s\n", (tls12 && tls13) ? "PASS" : "FAIL");
    printf("CAP external_trust=%s\n", external_trust ? "PASS" : "FAIL");
    printf("CAP partial_io_backpressure=%s\n", (tls12 && tls13) ? "PASS" : "FAIL");
    printf("CAP mtls=%s\n", mtls ? "PASS" : "FAIL");
    printf("CAP session_resumption=%s\n", session_resumption ? "PASS" : "FAIL");
    printf("CAP negative_hostname=%s\n", wrong_host ? "PASS" : "FAIL");
    printf("CAP negative_untrusted_ca=%s\n", untrusted ? "PASS" : "FAIL");
    printf("CAP close_notify=%s\n", (tls12 && tls13) ? "PASS" : "FAIL");
    printf("CAP truncation=%s\n", trunc ? "PASS" : "FAIL");
    printf("CAP caller_cancellation=%s\n", cancel ? "PASS" : "FAIL");
#if defined(OPENSSL_IS_AWSLC)
    printf("CAP external_signer=%s\n", external_signer ? "PASS" : "FAIL");
#else
    printf("CAP external_signer=BLOCKED\n");
#endif
    printf("CAP repeated_cleanup=%s\n", cleanup ? "PASS" : "FAIL");
    printf("METRIC repeated_cleanup_cycles=%d\n", CLEANUP_CYCLES);
    printf("METRIC failure_cleanup_cycles=%d\n", FAILURE_CLEANUP_CYCLES);
    printf("METRIC session_resumption_handshakes=%u\n",
           session_resumption_tls12_handshakes +
           session_resumption_tls13_handshakes);
    printf("METRIC session_resumption_tls12_handshakes=%u\n",
           session_resumption_tls12_handshakes);
    printf("METRIC session_resumption_tls13_handshakes=%u\n",
           session_resumption_tls13_handshakes);
    printf("METRIC external_trust_calls=%u\n", external_trust_calls);
#if defined(OPENSSL_IS_AWSLC)
    printf("METRIC external_signer_calls=%u\n", external_signer_calls);
#endif

    return (tls12 && tls13 && mtls && session_resumption && external_trust && wrong_host &&
            untrusted && trunc && cancel &&
            cleanup && failure_cleanup &&
#if defined(OPENSSL_IS_AWSLC)
            external_signer &&
#endif
            1) ? 0 : 1;
}
