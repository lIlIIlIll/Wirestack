#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

typedef int (*getaddrinfo_fn)(const char *, const char *, const struct addrinfo *, struct addrinfo **);
static getaddrinfo_fn real_getaddrinfo;
static pthread_once_t resolve_once = PTHREAD_ONCE_INIT;
static atomic_ullong sequence = 0;

static void resolve_real(void) {
    real_getaddrinfo = (getaddrinfo_fn)dlsym(RTLD_NEXT, "getaddrinfo");
}

static long long monotonic_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

static long gettid_value(void) {
    return (long)syscall(SYS_gettid);
}

static unsigned long parse_delay_ms(void) {
    const char *value = getenv("WIRESTACK_GAI_DELAY_MS");
    if (!value || !*value) return 0;
    char *end = NULL;
    errno = 0;
    unsigned long delay = strtoul(value, &end, 10);
    if (errno || end == value || *end != '\0' || delay > 60000UL) return 0;
    return delay;
}

static void append_log(const char *phase, unsigned long long seq,
                       const char *node, long long timestamp_ns, int result) {
    const char *path = getenv("WIRESTACK_GAI_LOG");
    if (!path || !*path) return;
    int fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0600);
    if (fd < 0) return;
    char buffer[1024];
    int length = snprintf(buffer, sizeof(buffer),
        "GAI phase=%s seq=%llu pid=%ld tid=%ld ns=%lld result=%d node=%s\n",
        phase, seq, (long)getpid(), gettid_value(), timestamp_ns, result,
        node ? node : "(null)");
    if (length > 0) {
        size_t amount = (size_t)length < sizeof(buffer) ? (size_t)length : sizeof(buffer) - 1;
        (void)write(fd, buffer, amount);
    }
    close(fd);
}

int getaddrinfo(const char *node, const char *service,
                const struct addrinfo *hints, struct addrinfo **result) {
    pthread_once(&resolve_once, resolve_real);
    if (!real_getaddrinfo) return EAI_SYSTEM;
    unsigned long long seq = atomic_fetch_add_explicit(&sequence, 1, memory_order_relaxed);
    append_log("enter", seq, node, monotonic_ns(), 0);
    unsigned long delay_ms = parse_delay_ms();
    if (delay_ms > 0) {
        struct timespec requested = {
            .tv_sec = (time_t)(delay_ms / 1000UL),
            .tv_nsec = (long)((delay_ms % 1000UL) * 1000000UL),
        };
        while (nanosleep(&requested, &requested) != 0 && errno == EINTR) {}
    }
    int rc = real_getaddrinfo(node, service, hints, result);
    append_log("exit", seq, node, monotonic_ns(), rc);
    return rc;
}
