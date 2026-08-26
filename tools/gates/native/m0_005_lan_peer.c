#define _POSIX_C_SOURCE 200809L

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/utsname.h>
#include <unistd.h>

enum { CHUNK_SIZE = 64 * 1024, ACCEPT_TIMEOUT_MS = 180000 };

static const uint64_t PAYLOADS[] = {
    0,
    1024,
    16 * 1024,
    64 * 1024,
    1024 * 1024,
    100 * 1024 * 1024,
};

static void fail(const char *operation) {
    fprintf(stderr, "ERROR operation=%s errno=%d\n", operation, errno);
    exit(1);
}

static int accept_bounded(int listener) {
    struct pollfd descriptor = {.fd = listener, .events = POLLIN, .revents = 0};
    int ready;
    do {
        ready = poll(&descriptor, 1, ACCEPT_TIMEOUT_MS);
    } while (ready < 0 && errno == EINTR);
    if (ready == 0) {
        errno = ETIMEDOUT;
        fail("accept-timeout");
    }
    if (ready < 0 || !(descriptor.revents & POLLIN)) {
        fail("poll-accept");
    }
    int connection;
    do {
        connection = accept(listener, NULL, NULL);
    } while (connection < 0 && errno == EINTR);
    if (connection < 0) {
        fail("accept");
    }
    return connection;
}

static void send_all(int connection, const unsigned char *data, size_t length) {
    size_t offset = 0;
    while (offset < length) {
        ssize_t sent = send(connection, data + offset, length - offset, MSG_NOSIGNAL);
        if (sent < 0 && errno == EINTR) {
            continue;
        }
        if (sent <= 0) {
            fail("send");
        }
        offset += (size_t)sent;
    }
}

static void serve_metadata(int listener) {
    struct utsname identity;
    if (uname(&identity) != 0) {
        fail("uname");
    }
    char message[512];
    int length = snprintf(
        message,
        sizeof(message),
        "WIRESTACK_M0_005_PEER schema=1 sysname=%s release=%s machine=%s "
        "payload_count=%zu\n",
        identity.sysname,
        identity.release,
        identity.machine,
        sizeof(PAYLOADS) / sizeof(PAYLOADS[0])
    );
    if (length <= 0 || (size_t)length >= sizeof(message)) {
        errno = EOVERFLOW;
        fail("metadata-format");
    }
    int connection = accept_bounded(listener);
    send_all(connection, (const unsigned char *)message, (size_t)length);
    close(connection);
}

static void serve_payload(int listener, const unsigned char *chunk, uint64_t payload) {
    int connection = accept_bounded(listener);
    uint64_t remaining = payload;
    while (remaining > 0) {
        size_t length = remaining < CHUNK_SIZE ? (size_t)remaining : CHUNK_SIZE;
        send_all(connection, chunk, length);
        remaining -= length;
    }
    if (shutdown(connection, SHUT_WR) != 0 && errno != ENOTCONN) {
        fail("shutdown-write");
    }
    close(connection);
}

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: %s PORT REPETITIONS_PER_PAYLOAD\n", argv[0]);
        return 2;
    }
    char *end = NULL;
    long port = strtol(argv[1], &end, 10);
    if (!end || *end != '\0' || port <= 0 || port > 65535) {
        fprintf(stderr, "ERROR invalid-port\n");
        return 2;
    }
    end = NULL;
    long repetitions = strtol(argv[2], &end, 10);
    if (!end || *end != '\0' || repetitions <= 0 || repetitions > 100) {
        fprintf(stderr, "ERROR invalid-repetitions\n");
        return 2;
    }

    signal(SIGPIPE, SIG_IGN);
    int listener = socket(AF_INET, SOCK_STREAM, 0);
    if (listener < 0) {
        fail("socket");
    }
    int enabled = 1;
    if (setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &enabled, sizeof(enabled)) != 0) {
        fail("reuseaddr");
    }
    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_port = htons((uint16_t)port);
    address.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(listener, (struct sockaddr *)&address, sizeof(address)) != 0) {
        fail("bind");
    }
    if (listen(listener, 8) != 0) {
        fail("listen");
    }

    unsigned char *chunk = malloc(CHUNK_SIZE);
    if (!chunk) {
        fail("malloc");
    }
    memset(chunk, 37, CHUNK_SIZE);
    printf("READY schema=1 port=%ld repetitions=%ld pid=%ld\n", port, repetitions,
           (long)getpid());
    fflush(stdout);

    serve_metadata(listener);
    size_t payload_count = sizeof(PAYLOADS) / sizeof(PAYLOADS[0]);
    uint64_t bytes_per_matrix = 0;
    for (size_t payload_index = 0; payload_index < payload_count; payload_index++) {
        bytes_per_matrix += PAYLOADS[payload_index];
        for (long repetition = 0; repetition < repetitions; repetition++) {
            serve_payload(listener, chunk, PAYLOADS[payload_index]);
            printf("SERVED payload=%llu repetition=%ld\n",
                   (unsigned long long)PAYLOADS[payload_index], repetition + 1);
            fflush(stdout);
        }
    }
    printf("RESULT status=PASS connections=%zu bytes_per_matrix=%llu\n",
           payload_count * (size_t)repetitions,
           (unsigned long long)bytes_per_matrix);
    fflush(stdout);
    free(chunk);
    close(listener);
    return 0;
}
