#define _GNU_SOURCE

#include <arpa/inet.h>
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
#include <sys/socket.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

typedef int (*getaddrinfo_fn)(const char *, const char *, const struct addrinfo *, struct addrinfo **);
typedef void (*freeaddrinfo_fn)(struct addrinfo *);

struct fixture_result {
    struct addrinfo *head;
    struct fixture_result *next;
};

static getaddrinfo_fn real_getaddrinfo;
static freeaddrinfo_fn real_freeaddrinfo;
static pthread_once_t resolve_once = PTHREAD_ONCE_INIT;
static pthread_mutex_t fixture_mutex = PTHREAD_MUTEX_INITIALIZER;
static struct fixture_result *fixture_results;
static atomic_ullong sequence = 0;

static void resolve_real(void) {
    real_getaddrinfo = (getaddrinfo_fn)dlsym(RTLD_NEXT, "getaddrinfo");
    real_freeaddrinfo = (freeaddrinfo_fn)dlsym(RTLD_NEXT, "freeaddrinfo");
}

static long long monotonic_ns(void) {
    struct timespec value;
    clock_gettime(CLOCK_MONOTONIC, &value);
    return (long long)value.tv_sec * 1000000000LL + value.tv_nsec;
}

static long native_tid(void) {
    return (long)syscall(SYS_gettid);
}

static void log_event(const char *phase, unsigned long long call_sequence,
                      const char *host, int family, int result) {
    const char *path = getenv("WIRESTACK_M2_005_GAI_LOG");
    if (path == NULL || path[0] == '\0') {
        return;
    }
    int fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0600);
    if (fd < 0) {
        return;
    }
    char buffer[1024];
    int length = snprintf(
        buffer,
        sizeof(buffer),
        "M2005_GAI phase=%s seq=%llu pid=%ld tid=%ld ns=%lld family=%d result=%d host=%s\n",
        phase,
        call_sequence,
        (long)getpid(),
        native_tid(),
        monotonic_ns(),
        family,
        result,
        host == NULL ? "(null)" : host
    );
    if (length > 0) {
        size_t amount = (size_t)length < sizeof(buffer) ? (size_t)length : sizeof(buffer) - 1u;
        size_t offset = 0u;
        while (offset < amount) {
            ssize_t written = write(fd, buffer + offset, amount - offset);
            if (written > 0) {
                offset += (size_t)written;
            } else if (written < 0 && errno == EINTR) {
                continue;
            } else {
                break;
            }
        }
    }
    close(fd);
}

static void delay_200_ms(void) {
    struct timespec remaining = {.tv_sec = 0, .tv_nsec = 200000000L};
    while (nanosleep(&remaining, &remaining) != 0 && errno == EINTR) {}
}

static void free_fixture_chain(struct addrinfo *head) {
    while (head != NULL) {
        struct addrinfo *next = head->ai_next;
        free(head->ai_addr);
        free(head);
        head = next;
    }
}

static int register_fixture_result(struct addrinfo *head) {
    struct fixture_result *entry = (struct fixture_result *)malloc(sizeof(*entry));
    if (entry == NULL) {
        return 0;
    }
    entry->head = head;
    pthread_mutex_lock(&fixture_mutex);
    entry->next = fixture_results;
    fixture_results = entry;
    pthread_mutex_unlock(&fixture_mutex);
    return 1;
}

static int take_fixture_result(struct addrinfo *head) {
    int found = 0;
    pthread_mutex_lock(&fixture_mutex);
    struct fixture_result **cursor = &fixture_results;
    while (*cursor != NULL) {
        if ((*cursor)->head == head) {
            struct fixture_result *removed = *cursor;
            *cursor = removed->next;
            free(removed);
            found = 1;
            break;
        }
        cursor = &(*cursor)->next;
    }
    pthread_mutex_unlock(&fixture_mutex);
    return found;
}

static int append_address(struct addrinfo **head, struct addrinfo **tail,
                          int family, const uint8_t *bytes) {
    struct addrinfo *entry = (struct addrinfo *)calloc(1u, sizeof(*entry));
    if (entry == NULL) {
        return 0;
    }
    entry->ai_family = family;
    entry->ai_socktype = SOCK_STREAM;
    entry->ai_protocol = IPPROTO_TCP;
    if (family == AF_INET) {
        struct sockaddr_in *address = (struct sockaddr_in *)calloc(1u, sizeof(*address));
        if (address == NULL) {
            free(entry);
            return 0;
        }
        address->sin_family = AF_INET;
        memcpy(&address->sin_addr, bytes, 4u);
        entry->ai_addr = (struct sockaddr *)address;
        entry->ai_addrlen = (socklen_t)sizeof(*address);
    } else if (family == AF_INET6) {
        struct sockaddr_in6 *address = (struct sockaddr_in6 *)calloc(1u, sizeof(*address));
        if (address == NULL) {
            free(entry);
            return 0;
        }
        address->sin6_family = AF_INET6;
        memcpy(&address->sin6_addr, bytes, 16u);
        entry->ai_addr = (struct sockaddr *)address;
        entry->ai_addrlen = (socklen_t)sizeof(*address);
    }
    if (*tail == NULL) {
        *head = entry;
    } else {
        (*tail)->ai_next = entry;
    }
    *tail = entry;
    return 1;
}

static int fixture_addresses(int requested_family, struct addrinfo **result) {
    const uint8_t ipv4[4] = {127u, 0u, 0u, 1u};
    const uint8_t ipv6[16] = {0u, 0u, 0u, 0u, 0u, 0u, 0u, 0u,
                              0u, 0u, 0u, 0u, 0u, 0u, 0u, 1u};
    struct addrinfo *head = NULL;
    struct addrinfo *tail = NULL;
    if ((requested_family == AF_UNSPEC || requested_family == AF_INET6) &&
        !append_address(&head, &tail, AF_INET6, ipv6)) {
        free_fixture_chain(head);
        return EAI_MEMORY;
    }
    if ((requested_family == AF_UNSPEC || requested_family == AF_INET) &&
        !append_address(&head, &tail, AF_INET, ipv4)) {
        free_fixture_chain(head);
        return EAI_MEMORY;
    }
    if ((requested_family == AF_UNSPEC || requested_family == AF_INET6) &&
        !append_address(&head, &tail, AF_INET6, ipv6)) {
        free_fixture_chain(head);
        return EAI_MEMORY;
    }
    if (head == NULL) {
        return EAI_FAMILY;
    }
    if (!register_fixture_result(head)) {
        free_fixture_chain(head);
        return EAI_MEMORY;
    }
    *result = head;
    return 0;
}

static int fixture_no_data(struct addrinfo **result) {
    struct addrinfo *head = NULL;
    struct addrinfo *tail = NULL;
    const uint8_t unused[16] = {0u};
    if (!append_address(&head, &tail, AF_UNIX, unused)) {
        return EAI_MEMORY;
    }
    if (!register_fixture_result(head)) {
        free_fixture_chain(head);
        return EAI_MEMORY;
    }
    *result = head;
    return 0;
}

int getaddrinfo(const char *host, const char *service,
                const struct addrinfo *hints, struct addrinfo **result) {
    (void)service;
    pthread_once(&resolve_once, resolve_real);
    if (result == NULL) {
        return EAI_FAIL;
    }
    *result = NULL;
    int family = hints == NULL ? AF_UNSPEC : hints->ai_family;
    unsigned long long call_sequence =
        atomic_fetch_add_explicit(&sequence, 1u, memory_order_relaxed);
    log_event("enter", call_sequence, host, family, 0);
    int status;
    if (host != NULL && strcmp(host, "all.m2-005.test") == 0) {
        status = fixture_addresses(family, result);
    } else if (host != NULL && strcmp(host, "delay.m2-005.test") == 0) {
        delay_200_ms();
        status = fixture_addresses(family, result);
    } else if (host != NULL && strcmp(host, "noname.m2-005.test") == 0) {
        status = EAI_NONAME;
    } else if (host != NULL && strcmp(host, "nodata.m2-005.test") == 0) {
        status = fixture_no_data(result);
    } else if (host != NULL && strcmp(host, "again.m2-005.test") == 0) {
        status = EAI_AGAIN;
    } else if (host != NULL && strcmp(host, "family.m2-005.test") == 0) {
        status = EAI_FAMILY;
    } else if (host != NULL && strcmp(host, "system.m2-005.test") == 0) {
        errno = EACCES;
        status = EAI_SYSTEM;
    } else if (real_getaddrinfo != NULL) {
        status = real_getaddrinfo(host, service, hints, result);
    } else {
        status = EAI_SYSTEM;
    }
    log_event("exit", call_sequence, host, family, status);
    return status;
}

void freeaddrinfo(struct addrinfo *result) {
    pthread_once(&resolve_once, resolve_real);
    if (result != NULL && take_fixture_result(result)) {
        free_fixture_chain(result);
    } else if (real_freeaddrinfo != NULL) {
        real_freeaddrinfo(result);
    }
}
