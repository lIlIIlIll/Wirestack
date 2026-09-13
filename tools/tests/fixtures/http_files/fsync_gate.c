#define _GNU_SOURCE

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

typedef int (*fsync_fn)(int);

static fsync_fn real_fsync;
static pthread_once_t resolve_once = PTHREAD_ONCE_INIT;

static void resolve_real_fsync(void) {
    real_fsync = (fsync_fn)dlsym(RTLD_NEXT, "fsync");
}

static int upload_staging_descriptor(int descriptor) {
    const char *root = getenv("WIRESTACK_HTTP_FILES_COMMIT_ROOT");
    if (root == NULL || root[0] == '\0') {
        return 0;
    }

    char descriptor_path[64];
    int descriptor_length = snprintf(
        descriptor_path, sizeof(descriptor_path), "/proc/self/fd/%d", descriptor);
    if (descriptor_length <= 0 || (size_t)descriptor_length >= sizeof(descriptor_path)) {
        return 0;
    }

    char target[PATH_MAX + 1];
    ssize_t target_length = readlink(descriptor_path, target, PATH_MAX);
    if (target_length <= 0) {
        return 0;
    }
    target[target_length] = '\0';

    size_t root_length = strlen(root);
    static const char staging_prefix[] = "/.wirestack-upload-";
    return (size_t)target_length > root_length &&
        strncmp(target, root, root_length) == 0 &&
        strncmp(target + root_length, staging_prefix, sizeof(staging_prefix) - 1u) == 0;
}

static int create_marker(const char *path) {
    int marker = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    if (marker < 0) {
        return errno == EEXIST ? 0 : -1;
    }
    static const char value[] = "fsync-entered\n";
    ssize_t ignored = write(marker, value, sizeof(value) - 1u);
    (void)ignored;
    return close(marker);
}

static int wait_for_release(const char *path) {
    const struct timespec pause = {.tv_sec = 0, .tv_nsec = 1000000L};
    for (unsigned int attempt = 0; attempt < 10000u; attempt++) {
        if (access(path, F_OK) == 0) {
            return 0;
        }
        if (errno != ENOENT) {
            return -1;
        }
        struct timespec remaining = pause;
        while (nanosleep(&remaining, &remaining) != 0 && errno == EINTR) {}
    }
    errno = ETIMEDOUT;
    return -1;
}

int fsync(int descriptor) {
    pthread_once(&resolve_once, resolve_real_fsync);
    if (real_fsync == NULL) {
        errno = ENOSYS;
        return -1;
    }
    if (!upload_staging_descriptor(descriptor)) {
        return real_fsync(descriptor);
    }

    const char *entered = getenv("WIRESTACK_HTTP_FILES_COMMIT_ENTERED");
    const char *release = getenv("WIRESTACK_HTTP_FILES_COMMIT_RELEASE");
    if (entered == NULL || entered[0] == '\0' || release == NULL || release[0] == '\0') {
        errno = EINVAL;
        return -1;
    }
    if (create_marker(entered) != 0 || wait_for_release(release) != 0) {
        return -1;
    }
    return real_fsync(descriptor);
}
