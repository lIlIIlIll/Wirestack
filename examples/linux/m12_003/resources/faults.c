#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <sys/resource.h>
#include <time.h>
#include <unistd.h>

static int owned[512];
static int count;
int64_t resource_fd_limit(void) { struct rlimit r; return getrlimit(RLIMIT_NOFILE, &r) == 0 ? (int64_t)r.rlim_cur : -1; }
int64_t resource_fd_exhaust(void) {
    while (count < 512) { int fd = open("/dev/null", O_RDONLY | O_CLOEXEC); if (fd < 0) return errno == EMFILE ? count : -errno; owned[count++] = fd; }
    return -1;
}
void resource_fd_release(void) { while (count) close(owned[--count]); }
int64_t resource_burn(void) {
    struct timespec start, now;
    if (clock_gettime(CLOCK_THREAD_CPUTIME_ID, &start)) return -1;
    volatile uint64_t value = 17;
    do { for (int i = 0; i < 100000; i++) value = value * 1664525 + 1013904223;
        if (clock_gettime(CLOCK_THREAD_CPUTIME_ID, &now)) return -1;
    } while ((now.tv_sec-start.tv_sec)*1000000000LL+now.tv_nsec-start.tv_nsec < 600000000LL);
    return value != 0;
}
