/* Test fixture only. Wirestack never loads or guesses a system TLS provider. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <link.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <openssl/ssl.h>
#include <openssl/err.h>
#include <limits.h>
#include <pthread.h>

#define LOAD(name) __typeof__(&name) p_##name = (__typeof__(&name))dlsym(module, #name); if (!p_##name) return 11
int32_t fixture_independent_tls(uint16_t port) {
    const char *library = getenv("WIRESTACK_FIXTURE_OPENSSL_LIBRARY");
    const char *certificate = getenv("WIRESTACK_FIXTURE_CA_FILE");
    if (!library || library[0] != '/' || !certificate) return 10;
    /* Test-only symbol group isolation keeps the process's one libc/pthread
       key allocator. Duplicating libc with dlmopen corrupts shared-worker TSD. */
    void *module = dlopen(library, RTLD_NOW | RTLD_LOCAL | RTLD_DEEPBIND);
    if (!module) { fprintf(stderr, "fixture dlopen: %s\n", dlerror()); return 12; }
    LOAD(OpenSSL_version); LOAD(TLS_client_method); LOAD(SSL_CTX_new);
    LOAD(SSL_CTX_load_verify_locations); LOAD(SSL_CTX_set_verify); LOAD(SSL_new);
    LOAD(SSL_set_fd); LOAD(SSL_set1_host); LOAD(SSL_connect); LOAD(SSL_get_verify_result);
    LOAD(SSL_write); LOAD(SSL_read); LOAD(SSL_shutdown); LOAD(SSL_free); LOAD(SSL_CTX_free);
    LOAD(SSL_set_alpn_protos); LOAD(SSL_ctrl); LOAD(ERR_get_error); LOAD(ERR_error_string_n);
    const char *identity = p_OpenSSL_version(0);
    if (!identity || strncmp(identity, "OpenSSL 3.", 10) != 0) return 13;
    Dl_info owner;
    char library_path[PATH_MAX], owner_path[PATH_MAX];
    if (!dladdr((void *)p_SSL_connect, &owner) || !owner.dli_fname ||
        !realpath(library, library_path) || !realpath(owner.dli_fname, owner_path) ||
        strcmp(library_path, owner_path) != 0) return 14;
    const char *crypto_library = getenv("WIRESTACK_FIXTURE_OPENSSL_CRYPTO_LIBRARY");
    Dl_info crypto_owner, base_libc_owner, independent_libc_owner;
    char crypto_path[PATH_MAX];
    __typeof__(&pthread_getspecific) isolated_getspecific = (__typeof__(&pthread_getspecific))dlsym(module, "pthread_getspecific");
    __typeof__(&pthread_create) isolated_create = (__typeof__(&pthread_create))dlsym(module, "pthread_create");
    __typeof__(&pthread_key_create) isolated_key_create = (__typeof__(&pthread_key_create))dlsym(module, "pthread_key_create");
    if (!crypto_library || crypto_library[0] != '/' ||
        !dladdr((void *)p_OpenSSL_version, &crypto_owner) || !crypto_owner.dli_fname ||
        !realpath(crypto_library, crypto_path) || !realpath(crypto_owner.dli_fname, owner_path) ||
        strcmp(crypto_path, owner_path) != 0 || (void *)p_OpenSSL_version == (void *)&OpenSSL_version) return 19;
    if (isolated_getspecific != &pthread_getspecific || isolated_create != &pthread_create || isolated_key_create != &pthread_key_create ||
        !dladdr((void *)&pthread_getspecific, &base_libc_owner) ||
        !dladdr((void *)isolated_getspecific, &independent_libc_owner) ||
        base_libc_owner.dli_fbase != independent_libc_owner.dli_fbase) return 20;
    printf("BOUNDARY crypto OpenSSL_version global=%p independent=%p owners_distinct=1 independent_owner=%s\n",
           (void *)&OpenSSL_version, (void *)p_OpenSSL_version, crypto_owner.dli_fname);
    printf("BOUNDARY libc pthread_getspecific global=%p independent=%p owner_shared=1 pthread_create_shared=1 pthread_key_create_shared=1\n",
           (void *)&pthread_getspecific, (void *)isolated_getspecific);
    Dl_info global_owner;
    const char *global_identity = OpenSSL_version(0);
    if (!global_identity || !strstr(global_identity, "AWS-LC") ||
        !dladdr((void *)&SSL_connect, &global_owner) ||
        (void *)p_SSL_connect == (void *)&SSL_connect || owner.dli_fbase == global_owner.dli_fbase) return 17;
    printf("BOUNDARY symbols SSL_connect global=%p isolated=%p owners_distinct=1 global_owner=%s independent_owner=%s\n",
           (void *)&SSL_connect, (void *)p_SSL_connect, global_owner.dli_fname, owner.dli_fname);
    /* Concrete unisolated boundary: this object's OpenSSL-header symbol resolves
       to AWS-LC in the executable, not OpenSSL 3. Never pass OpenSSL handles there. */
    printf("BOUNDARY unisolated_openssl UNSUPPORTED resolved_identity=%s\n", global_identity);
    SSL_CTX *ctx = p_SSL_CTX_new(p_TLS_client_method());
    if (!ctx || p_SSL_CTX_load_verify_locations(ctx, certificate, NULL) != 1) return 15;
    p_SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, NULL);
    SSL *ssl = p_SSL_new(ctx);
    const unsigned char alpn[] = {8, 'h', 't', 't', 'p', '/', '1', '.', '1'};
    if (!ssl || p_SSL_set_alpn_protos(ssl, alpn, sizeof(alpn)) != 0 ||
        p_SSL_ctrl(ssl, SSL_CTRL_SET_TLSEXT_HOSTNAME, TLSEXT_NAMETYPE_host_name, (void *)"example.test") != 1) return 18;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    struct timeval budget = {10, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &budget, sizeof(budget));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &budget, sizeof(budget));
    struct sockaddr_in address = {.sin_family = AF_INET, .sin_port = htons(port)};
    inet_pton(AF_INET, "127.0.0.1", &address.sin_addr);
    int result = 16;
    if (ssl && fd >= 0 && connect(fd, (struct sockaddr *)&address, sizeof(address)) == 0 &&
        p_SSL_set_fd(ssl, fd) == 1 && p_SSL_set1_host(ssl, "example.test") == 1 &&
        p_SSL_connect(ssl) == 1 && p_SSL_get_verify_result(ssl) == X509_V_OK) {
        const char request[] = "GET / HTTP/1.1\r\nHost: example.test\r\nConnection: close\r\n\r\n";
        char response[4096] = {0}; size_t used = 0;
        if (p_SSL_write(ssl, request, sizeof(request)-1) == sizeof(request)-1) {
            while (used < sizeof(response)-1) {
                int n = p_SSL_read(ssl, response + used, (int)(sizeof(response)-1-used));
                if (n <= 0) break;
                used += (size_t)n;
            }
            if (strstr(response, "HTTP/1.1 200") && strstr(response, "coexist-native-work")) {
                printf("IDENTITY independent_tls %s isolation=deepbind libc=shared verified_peer=example.test bytes=%zu\n", identity, used);
                result = 0;
            }
        }
    }
    if (result != 0) {
        unsigned long error;
        while ((error = p_ERR_get_error()) != 0) {
            char diagnostic[256]; p_ERR_error_string_n(error, diagnostic, sizeof(diagnostic));
            fprintf(stderr, "fixture TLS failure: %s\n", diagnostic);
        }
        fprintf(stderr, "fixture verified TLS/HTTP did not complete, result=%d\n", result);
    }
    if (ssl) { p_SSL_shutdown(ssl); p_SSL_free(ssl); }
    if (fd >= 0) close(fd);
    p_SSL_CTX_free(ctx);
    dlclose(module);
    return result;
}
int64_t fixture_native_sum(int64_t value) { return value * 17 + (getpid() > 0 ? 5 : 0); }
