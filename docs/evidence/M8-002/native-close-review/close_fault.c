#define _GNU_SOURCE
#include <arpa/inet.h>
#include <dlfcn.h>
#include <errno.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <unistd.h>
static _Atomic int selected_fd = -1;
static _Atomic int calls = 0;
static _Atomic int first_result = -99;
int close(int fd) {
    int (*real_close)(int) = dlsym(RTLD_NEXT, "close");
    if (atomic_load(&selected_fd) == -1) {
        struct sockaddr_in address;
        socklen_t length = sizeof(address);
        int type = 0;
        socklen_t type_length = sizeof(type);
        const char *port = getenv("WIRESTACK_CLOSE_PORT");
        if (port && getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &type_length) == 0 &&
            type == SOCK_DGRAM && getsockname(fd, (struct sockaddr *)&address, &length) == 0 &&
            address.sin_family == AF_INET && ntohs(address.sin_port) == atoi(port)) {
            atomic_store(&selected_fd, fd);
        }
    }
    if (fd == atomic_load(&selected_fd)) {
        int call = atomic_fetch_add(&calls, 1) + 1;
        int result = real_close(fd);
        if (call == 1) {
            atomic_store(&first_result, result);
            errno = EIO;
            return -1;
        }
        return result;
    }
    return real_close(fd);
}
__attribute__((destructor)) static void report(void) {
    char output[128];
    int size = snprintf(output, sizeof(output), "NATIVE_CLOSE_CALLS=%d FIRST_REAL_CLOSE_RESULT=%d\n",
        atomic_load(&calls), atomic_load(&first_result));
    if (size > 0) { (void)write(STDERR_FILENO, output, (size_t)size); }
}
