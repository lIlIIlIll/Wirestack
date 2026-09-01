#if !defined(__APPLE__)
#error "the Apple resolver adapter must be compiled for an Apple target"
#endif

/*
 * Darwin and Linux use the same bounded POSIX worker implementation. The
 * Apple adapter owns only platform binding and deterministic test injection;
 * it does not introduce a second timeout, cancellation, or cache owner.
 */
#if defined(WIRESTACK_RESOLVER_TEST_FIXTURE)
#define _POSIX_C_SOURCE 200809L
#include <arpa/inet.h>
#include <errno.h>
#include <netdb.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static int wirestack_apple_getaddrinfo(
    const char *host,
    const char *service,
    const struct addrinfo *hints,
    struct addrinfo **results
);
static void wirestack_apple_freeaddrinfo(struct addrinfo *results);

#define getaddrinfo wirestack_apple_getaddrinfo
#define freeaddrinfo wirestack_apple_freeaddrinfo
#endif

#include "../linux/wirestack_resolver.c"

#if defined(WIRESTACK_RESOLVER_TEST_FIXTURE)
#undef getaddrinfo
#undef freeaddrinfo

struct wirestack_apple_fixture_node {
    struct addrinfo info;
    struct sockaddr_storage address;
};

static const char wirestack_apple_fixture_marker[] = "wirestack-m2-006-fixture";
static atomic_uint wirestack_apple_fixture_generation = 0u;

static int fixture_family_allowed(const struct addrinfo *hints, int family) {
    return hints == NULL || hints->ai_family == AF_UNSPEC || hints->ai_family == family;
}

static struct addrinfo *fixture_node(int family, const uint8_t *bytes, size_t size) {
    struct wirestack_apple_fixture_node *node =
        (struct wirestack_apple_fixture_node *)calloc(1u, sizeof(*node));
    if (node == NULL) {
        return NULL;
    }
    node->info.ai_family = family;
    node->info.ai_socktype = SOCK_STREAM;
    node->info.ai_canonname = (char *)wirestack_apple_fixture_marker;
    node->info.ai_addr = (struct sockaddr *)&node->address;
    if (family == AF_INET) {
        struct sockaddr_in *address = (struct sockaddr_in *)&node->address;
        address->sin_family = AF_INET;
        memcpy(&address->sin_addr, bytes, size);
        node->info.ai_addrlen = (socklen_t)sizeof(*address);
    } else {
        struct sockaddr_in6 *address = (struct sockaddr_in6 *)&node->address;
        address->sin6_family = AF_INET6;
        address->sin6_scope_id = 11u;
        memcpy(&address->sin6_addr, bytes, size);
        node->info.ai_addrlen = (socklen_t)sizeof(*address);
    }
    return &node->info;
}

static int append_fixture_node(
    struct addrinfo **head,
    struct addrinfo **tail,
    int family,
    const uint8_t *bytes,
    size_t size
) {
    struct addrinfo *node = fixture_node(family, bytes, size);
    if (node == NULL) {
        wirestack_apple_freeaddrinfo(*head);
        *head = NULL;
        *tail = NULL;
        return EAI_MEMORY;
    }
    if (*tail == NULL) {
        *head = node;
    } else {
        (*tail)->ai_next = node;
    }
    *tail = node;
    return 0;
}

static int fixture_addresses(
    const struct addrinfo *hints,
    struct addrinfo **results,
    uint8_t generation
) {
    static const uint8_t ipv6[16] = {
        0u, 0u, 0u, 0u, 0u, 0u, 0u, 0u,
        0u, 0u, 0u, 0u, 0u, 0u, 0u, 1u
    };
    uint8_t ipv4[4] = {198u, 51u, 100u, generation};
    struct addrinfo *head = NULL;
    struct addrinfo *tail = NULL;
    int status;
    if (fixture_family_allowed(hints, AF_INET6)) {
        status = append_fixture_node(&head, &tail, AF_INET6, ipv6, sizeof(ipv6));
        if (status != 0) {
            return status;
        }
    }
    if (fixture_family_allowed(hints, AF_INET)) {
        status = append_fixture_node(&head, &tail, AF_INET, ipv4, sizeof(ipv4));
        if (status != 0) {
            return status;
        }
    }
    *results = head;
    return head == NULL ? EAI_FAMILY : 0;
}

static int wirestack_apple_getaddrinfo(
    const char *host,
    const char *service,
    const struct addrinfo *hints,
    struct addrinfo **results
) {
    (void)service;
    *results = NULL;
    if (strcmp(host, "all.m2-006.test") == 0) {
        int status = fixture_addresses(hints, results, 1u);
        if (status == 0 && *results != NULL && (*results)->ai_next != NULL) {
            struct addrinfo *tail = (*results)->ai_next;
            while (tail->ai_next != NULL) {
                tail = tail->ai_next;
            }
            const uint8_t duplicate[4] = {198u, 51u, 100u, 1u};
            if (fixture_family_allowed(hints, AF_INET)) {
                return append_fixture_node(results, &tail, AF_INET, duplicate, sizeof(duplicate));
            }
        }
        return status;
    }
    if (strcmp(host, "delay.m2-006.test") == 0) {
        const struct timespec delay = {.tv_sec = 0, .tv_nsec = 250000000L};
        (void)nanosleep(&delay, NULL);
        return fixture_addresses(hints, results, 2u);
    }
    if (strcmp(host, "change.m2-006.test") == 0) {
        unsigned int current = atomic_fetch_add(&wirestack_apple_fixture_generation, 1u);
        return fixture_addresses(hints, results, (uint8_t)(10u + current % 200u));
    }
    if (strcmp(host, "noname.m2-006.test") == 0) {
        return EAI_NONAME;
    }
    if (strcmp(host, "again.m2-006.test") == 0) {
        return EAI_AGAIN;
    }
    if (strcmp(host, "family.m2-006.test") == 0) {
        return EAI_FAMILY;
    }
    if (strcmp(host, "system.m2-006.test") == 0) {
        errno = EIO;
        return EAI_SYSTEM;
    }
    if (strcmp(host, "unknown.m2-006.test") == 0) {
        return 123456;
    }
    return getaddrinfo(host, service, hints, results);
}

static void wirestack_apple_freeaddrinfo(struct addrinfo *results) {
    if (results == NULL) {
        return;
    }
    if (results->ai_canonname != wirestack_apple_fixture_marker) {
        freeaddrinfo(results);
        return;
    }
    while (results != NULL) {
        struct addrinfo *next = results->ai_next;
        free(results);
        results = next;
    }
}
#endif
