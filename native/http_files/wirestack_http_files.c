#define _GNU_SOURCE
#define _POSIX_C_SOURCE 200809L

#include "wirestack_http_files.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <unistd.h>

#define WIRESTACK_HTTP_FILES_ROOT_MAGIC UINT64_C(0x5753484652303031)
#define WIRESTACK_HTTP_FILES_FILE_MAGIC UINT64_C(0x5753484646303031)
#define WIRESTACK_HTTP_FILES_UPLOAD_MAGIC UINT64_C(0x5753484655303031)
#define WIRESTACK_HTTP_FILES_MAXIMUM_PATH_BYTES UINT64_C(4096)
#define WIRESTACK_HTTP_FILES_MAXIMUM_FILENAME_BYTES UINT64_C(1024)

struct wirestack_http_files_root {
    uint64_t magic;
    int descriptor;
};

struct wirestack_http_files_file {
    uint64_t magic;
    int descriptor;
    uint64_t length;
    uint64_t consumed;
};

struct wirestack_http_files_upload {
    uint64_t magic;
    int root_descriptor;
    int descriptor;
    char *temporary_name;
    char *final_name;
    uint64_t maximum_bytes;
    uint64_t written;
    int prepared;
};

static uint64_t upload_sequence = 1u;

static int32_t classify_errno(int value) {
    switch (value) {
        case ENOENT:
        case ENOTDIR:
            return WIRESTACK_HTTP_FILES_NOT_FOUND;
        case EACCES:
        case EPERM:
            return WIRESTACK_HTTP_FILES_PERMISSION_DENIED;
        case ELOOP:
            return WIRESTACK_HTTP_FILES_SYMLINK_REJECTED;
        case EEXIST:
            return WIRESTACK_HTTP_FILES_ALREADY_EXISTS;
        default:
            return WIRESTACK_HTTP_FILES_SYSTEM_FAILURE;
    }
}

static int32_t fail_errno(int value, int64_t *out_native_code) {
    if (out_native_code != NULL) {
        *out_native_code = (int64_t)value;
    }
    return classify_errno(value);
}

static char *copy_input(const uint8_t *value, uint64_t size, uint64_t maximum) {
    if (value == NULL || size == 0u || size > maximum || size > (uint64_t)SIZE_MAX - 1u) {
        errno = EINVAL;
        return NULL;
    }
    char *copy = (char *)malloc((size_t)size + 1u);
    if (copy == NULL) {
        errno = ENOMEM;
        return NULL;
    }
    memcpy(copy, value, (size_t)size);
    copy[size] = '\0';
    if (memchr(copy, '\0', (size_t)size) != NULL) {
        free(copy);
        errno = EINVAL;
        return NULL;
    }
    return copy;
}

static int valid_component(const char *start, size_t size) {
    if (size == 0u || (size == 1u && start[0] == '.') ||
        (size == 2u && start[0] == '.' && start[1] == '.')) {
        return 0;
    }
    for (size_t index = 0u; index < size; index++) {
        unsigned char value = (unsigned char)start[index];
        if (value == '\0' || value == '\\' || value < 0x20u || value == 0x7fu) {
            return 0;
        }
    }
    return 1;
}

static int valid_relative_path(const char *path, int filename_only) {
    if (path == NULL || path[0] == '\0' || path[0] == '/') {
        return 0;
    }
    const char *component = path;
    for (const char *current = path;; current++) {
        if (*current == '/' || *current == '\0') {
            size_t size = (size_t)(current - component);
            if (!valid_component(component, size)) {
                return 0;
            }
            if (*current == '\0') {
                return 1;
            }
            if (filename_only) {
                return 0;
            }
            component = current + 1;
        }
    }
}

static int duplicate_descriptor(int descriptor) {
#ifdef F_DUPFD_CLOEXEC
    return fcntl(descriptor, F_DUPFD_CLOEXEC, 0);
#else
    int duplicate = dup(descriptor);
    if (duplicate >= 0) {
        (void)fcntl(duplicate, F_SETFD, FD_CLOEXEC);
    }
    return duplicate;
#endif
}

static int open_relative_regular(int root_descriptor, const char *path, int64_t *native_code) {
    int parent = duplicate_descriptor(root_descriptor);
    if (parent < 0) {
        *native_code = (int64_t)errno;
        return -1;
    }

    const char *component = path;
    for (;;) {
        const char *slash = strchr(component, '/');
        if (slash == NULL) {
            int descriptor;
            do {
                descriptor = openat(parent, component,
                    O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
            } while (descriptor < 0 && errno == EINTR);
            if (descriptor < 0) {
                *native_code = (int64_t)errno;
            }
            close(parent);
            return descriptor;
        }

        size_t size = (size_t)(slash - component);
        char *name = (char *)malloc(size + 1u);
        if (name == NULL) {
            *native_code = (int64_t)ENOMEM;
            close(parent);
            return -1;
        }
        memcpy(name, component, size);
        name[size] = '\0';
        int next;
        do {
            next = openat(parent, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
        } while (next < 0 && errno == EINTR);
        int saved = errno;
        free(name);
        close(parent);
        if (next < 0) {
            *native_code = (int64_t)saved;
            return -1;
        }
        parent = next;
        component = slash + 1;
    }
}

static int rename_without_replace(int directory, const char *source, const char *destination) {
#if defined(SYS_renameat2)
    if (syscall(SYS_renameat2, directory, source, directory, destination, 1u) == 0) {
        return 0;
    }
    if (errno != ENOSYS && errno != EINVAL) {
        return -1;
    }
#endif
    if (linkat(directory, source, directory, destination, 0) != 0) {
        return -1;
    }
    if (unlinkat(directory, source, 0) != 0) {
        int saved = errno;
        (void)unlinkat(directory, destination, 0);
        errno = saved;
        return -1;
    }
    return 0;
}

static void destroy_upload(struct wirestack_http_files_upload *upload, int remove_temporary) {
    if (upload == NULL) {
        return;
    }
    if (upload->descriptor >= 0) {
        close(upload->descriptor);
        upload->descriptor = -1;
    }
    if (remove_temporary && upload->root_descriptor >= 0 && upload->temporary_name != NULL) {
        (void)unlinkat(upload->root_descriptor, upload->temporary_name, 0);
    }
    if (upload->root_descriptor >= 0) {
        close(upload->root_descriptor);
        upload->root_descriptor = -1;
    }
    upload->magic = 0u;
    free(upload->temporary_name);
    free(upload->final_name);
    free(upload);
}

uint32_t wirestack_http_files_abi_version(void) {
    return UINT32_C(1);
}

int32_t wirestack_http_files_root_open(
    const uint8_t *path,
    uint64_t path_size,
    uint64_t *out_root_handle,
    int64_t *out_native_code
) {
    if (out_root_handle == NULL || out_native_code == NULL) {
        return WIRESTACK_HTTP_FILES_INVALID_ARGUMENT;
    }
    *out_root_handle = 0u;
    *out_native_code = 0;
    char *owned = copy_input(path, path_size, WIRESTACK_HTTP_FILES_MAXIMUM_PATH_BYTES);
    if (owned == NULL) {
        return errno == ENOMEM ? WIRESTACK_HTTP_FILES_OUT_OF_MEMORY :
            WIRESTACK_HTTP_FILES_INVALID_ARGUMENT;
    }

    int descriptor;
    do {
        descriptor = open(owned, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    } while (descriptor < 0 && errno == EINTR);
    int saved = errno;
    free(owned);
    if (descriptor < 0) {
        return fail_errno(saved, out_native_code);
    }

    struct stat information;
    if (fstat(descriptor, &information) != 0) {
        saved = errno;
        close(descriptor);
        return fail_errno(saved, out_native_code);
    }
    if (!S_ISDIR(information.st_mode)) {
        close(descriptor);
        return WIRESTACK_HTTP_FILES_NONREGULAR;
    }

    struct wirestack_http_files_root *root =
        (struct wirestack_http_files_root *)calloc(1u, sizeof(*root));
    if (root == NULL) {
        close(descriptor);
        return WIRESTACK_HTTP_FILES_OUT_OF_MEMORY;
    }
    root->magic = WIRESTACK_HTTP_FILES_ROOT_MAGIC;
    root->descriptor = descriptor;
    *out_root_handle = (uint64_t)(uintptr_t)root;
    return WIRESTACK_HTTP_FILES_OK;
}

void wirestack_http_files_root_close(uint64_t root_handle) {
    struct wirestack_http_files_root *root =
        (struct wirestack_http_files_root *)(uintptr_t)root_handle;
    if (root == NULL || root->magic != WIRESTACK_HTTP_FILES_ROOT_MAGIC) {
        return;
    }
    root->magic = 0u;
    close(root->descriptor);
    root->descriptor = -1;
    free(root);
}

int32_t wirestack_http_files_download_open(
    uint64_t root_handle,
    const uint8_t *relative_path,
    uint64_t relative_path_size,
    uint64_t maximum_bytes,
    uint64_t *out_file_handle,
    uint64_t *out_file_size,
    int64_t *out_native_code
) {
    if (out_file_handle == NULL || out_file_size == NULL || out_native_code == NULL) {
        return WIRESTACK_HTTP_FILES_INVALID_ARGUMENT;
    }
    *out_file_handle = 0u;
    *out_file_size = 0u;
    *out_native_code = 0;
    struct wirestack_http_files_root *root =
        (struct wirestack_http_files_root *)(uintptr_t)root_handle;
    if (root == NULL || root->magic != WIRESTACK_HTTP_FILES_ROOT_MAGIC) {
        return WIRESTACK_HTTP_FILES_CLOSED;
    }
    char *path = copy_input(relative_path, relative_path_size,
        WIRESTACK_HTTP_FILES_MAXIMUM_PATH_BYTES);
    if (path == NULL) {
        return errno == ENOMEM ? WIRESTACK_HTTP_FILES_OUT_OF_MEMORY :
            WIRESTACK_HTTP_FILES_INVALID_ARGUMENT;
    }
    if (!valid_relative_path(path, 0)) {
        free(path);
        return WIRESTACK_HTTP_FILES_INVALID_ARGUMENT;
    }

    int64_t native_code = 0;
    int descriptor = open_relative_regular(root->descriptor, path, &native_code);
    free(path);
    if (descriptor < 0) {
        return fail_errno((int)native_code, out_native_code);
    }

    struct stat information;
    if (fstat(descriptor, &information) != 0) {
        int saved = errno;
        close(descriptor);
        return fail_errno(saved, out_native_code);
    }
    if (!S_ISREG(information.st_mode)) {
        close(descriptor);
        return WIRESTACK_HTTP_FILES_NONREGULAR;
    }
    if (information.st_size < 0 || (uint64_t)information.st_size > maximum_bytes) {
        close(descriptor);
        return WIRESTACK_HTTP_FILES_LIMIT_EXCEEDED;
    }

    struct wirestack_http_files_file *file =
        (struct wirestack_http_files_file *)calloc(1u, sizeof(*file));
    if (file == NULL) {
        close(descriptor);
        return WIRESTACK_HTTP_FILES_OUT_OF_MEMORY;
    }
    file->magic = WIRESTACK_HTTP_FILES_FILE_MAGIC;
    file->descriptor = descriptor;
    file->length = (uint64_t)information.st_size;
    file->consumed = 0u;
    *out_file_handle = (uint64_t)(uintptr_t)file;
    *out_file_size = file->length;
    return WIRESTACK_HTTP_FILES_OK;
}

int32_t wirestack_http_files_file_read(
    uint64_t file_handle,
    uint8_t *output,
    uint64_t output_capacity,
    uint64_t *out_count,
    int64_t *out_native_code
) {
    if (out_count == NULL || out_native_code == NULL ||
        (output == NULL && output_capacity != 0u) || output_capacity > (uint64_t)SSIZE_MAX) {
        return WIRESTACK_HTTP_FILES_INVALID_ARGUMENT;
    }
    *out_count = 0u;
    *out_native_code = 0;
    struct wirestack_http_files_file *file =
        (struct wirestack_http_files_file *)(uintptr_t)file_handle;
    if (file == NULL || file->magic != WIRESTACK_HTTP_FILES_FILE_MAGIC) {
        return WIRESTACK_HTTP_FILES_CLOSED;
    }
    if (output_capacity == 0u || file->consumed == file->length) {
        return WIRESTACK_HTTP_FILES_OK;
    }
    uint64_t remaining = file->length - file->consumed;
    size_t requested = (size_t)(output_capacity < remaining ? output_capacity : remaining);
    ssize_t count;
    do {
        count = read(file->descriptor, output, requested);
    } while (count < 0 && errno == EINTR);
    if (count < 0) {
        return fail_errno(errno, out_native_code);
    }
    if (count == 0) {
        return WIRESTACK_HTTP_FILES_FILE_CHANGED;
    }
    file->consumed += (uint64_t)count;
    *out_count = (uint64_t)count;
    return WIRESTACK_HTTP_FILES_OK;
}

void wirestack_http_files_file_close(uint64_t file_handle) {
    struct wirestack_http_files_file *file =
        (struct wirestack_http_files_file *)(uintptr_t)file_handle;
    if (file == NULL || file->magic != WIRESTACK_HTTP_FILES_FILE_MAGIC) {
        return;
    }
    file->magic = 0u;
    close(file->descriptor);
    file->descriptor = -1;
    free(file);
}

int32_t wirestack_http_files_upload_begin(
    uint64_t root_handle,
    const uint8_t *filename,
    uint64_t filename_size,
    uint64_t maximum_bytes,
    uint64_t *out_upload_handle,
    int64_t *out_native_code
) {
    if (out_upload_handle == NULL || out_native_code == NULL) {
        return WIRESTACK_HTTP_FILES_INVALID_ARGUMENT;
    }
    *out_upload_handle = 0u;
    *out_native_code = 0;
    struct wirestack_http_files_root *root =
        (struct wirestack_http_files_root *)(uintptr_t)root_handle;
    if (root == NULL || root->magic != WIRESTACK_HTTP_FILES_ROOT_MAGIC) {
        return WIRESTACK_HTTP_FILES_CLOSED;
    }
    char *final_name = copy_input(filename, filename_size,
        WIRESTACK_HTTP_FILES_MAXIMUM_FILENAME_BYTES);
    if (final_name == NULL) {
        return errno == ENOMEM ? WIRESTACK_HTTP_FILES_OUT_OF_MEMORY :
            WIRESTACK_HTTP_FILES_INVALID_ARGUMENT;
    }
    if (!valid_relative_path(final_name, 1)) {
        free(final_name);
        return WIRESTACK_HTTP_FILES_INVALID_ARGUMENT;
    }

    struct stat existing;
    if (fstatat(root->descriptor, final_name, &existing, AT_SYMLINK_NOFOLLOW) == 0) {
        free(final_name);
        return WIRESTACK_HTTP_FILES_ALREADY_EXISTS;
    }
    if (errno != ENOENT) {
        int saved = errno;
        free(final_name);
        return fail_errno(saved, out_native_code);
    }

    struct wirestack_http_files_upload *upload =
        (struct wirestack_http_files_upload *)calloc(1u, sizeof(*upload));
    if (upload == NULL) {
        free(final_name);
        return WIRESTACK_HTTP_FILES_OUT_OF_MEMORY;
    }
    upload->root_descriptor = duplicate_descriptor(root->descriptor);
    upload->descriptor = -1;
    upload->final_name = final_name;
    upload->maximum_bytes = maximum_bytes;
    if (upload->root_descriptor < 0) {
        int saved = errno;
        destroy_upload(upload, 0);
        return fail_errno(saved, out_native_code);
    }

    char temporary[96];
    int descriptor = -1;
    for (unsigned int attempt = 0u; attempt < 128u; attempt++) {
        uint64_t sequence = __atomic_fetch_add(&upload_sequence, 1u, __ATOMIC_RELAXED);
        int length = snprintf(temporary, sizeof(temporary), ".wirestack-upload-%ld-%llu",
            (long)getpid(), (unsigned long long)sequence);
        if (length <= 0 || (size_t)length >= sizeof(temporary)) {
            destroy_upload(upload, 0);
            return WIRESTACK_HTTP_FILES_SYSTEM_FAILURE;
        }
        do {
            descriptor = openat(upload->root_descriptor, temporary,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
        } while (descriptor < 0 && errno == EINTR);
        if (descriptor >= 0 || errno != EEXIST) {
            break;
        }
    }
    if (descriptor < 0) {
        int saved = errno;
        destroy_upload(upload, 0);
        return fail_errno(saved, out_native_code);
    }
    upload->temporary_name = strdup(temporary);
    if (upload->temporary_name == NULL) {
        close(descriptor);
        upload->descriptor = -1;
        (void)unlinkat(upload->root_descriptor, temporary, 0);
        destroy_upload(upload, 0);
        return WIRESTACK_HTTP_FILES_OUT_OF_MEMORY;
    }
    upload->descriptor = descriptor;
    upload->magic = WIRESTACK_HTTP_FILES_UPLOAD_MAGIC;
    *out_upload_handle = (uint64_t)(uintptr_t)upload;
    return WIRESTACK_HTTP_FILES_OK;
}

int32_t wirestack_http_files_upload_write(
    uint64_t upload_handle,
    const uint8_t *input,
    uint64_t input_size,
    int64_t *out_native_code
) {
    if (out_native_code == NULL || (input == NULL && input_size != 0u) || input_size > (uint64_t)SSIZE_MAX) {
        return WIRESTACK_HTTP_FILES_INVALID_ARGUMENT;
    }
    *out_native_code = 0;
    struct wirestack_http_files_upload *upload =
        (struct wirestack_http_files_upload *)(uintptr_t)upload_handle;
    if (upload == NULL || upload->magic != WIRESTACK_HTTP_FILES_UPLOAD_MAGIC || upload->descriptor < 0) {
        return WIRESTACK_HTTP_FILES_CLOSED;
    }
    if (input_size > upload->maximum_bytes - upload->written) {
        return WIRESTACK_HTTP_FILES_LIMIT_EXCEEDED;
    }
    uint64_t offset = 0u;
    while (offset < input_size) {
        ssize_t count;
        do {
            count = write(upload->descriptor, input + offset, (size_t)(input_size - offset));
        } while (count < 0 && errno == EINTR);
        if (count <= 0) {
            return fail_errno(count < 0 ? errno : EIO, out_native_code);
        }
        offset += (uint64_t)count;
    }
    upload->written += input_size;
    return WIRESTACK_HTTP_FILES_OK;
}

int32_t wirestack_http_files_upload_prepare(
    uint64_t upload_handle,
    int64_t *out_native_code
) {
    if (out_native_code == NULL) {
        return WIRESTACK_HTTP_FILES_INVALID_ARGUMENT;
    }
    *out_native_code = 0;
    struct wirestack_http_files_upload *upload =
        (struct wirestack_http_files_upload *)(uintptr_t)upload_handle;
    if (upload == NULL || upload->magic != WIRESTACK_HTTP_FILES_UPLOAD_MAGIC ||
        upload->descriptor < 0 || upload->prepared) {
        return WIRESTACK_HTTP_FILES_CLOSED;
    }
    if (fsync(upload->descriptor) != 0) {
        return fail_errno(errno, out_native_code);
    }
    /* Keep the fail-closed 0600 mode used for the staging inode. */
    if (close(upload->descriptor) != 0) {
        upload->descriptor = -1;
        return fail_errno(errno, out_native_code);
    }
    upload->descriptor = -1;
    upload->prepared = 1;
    return WIRESTACK_HTTP_FILES_OK;
}

int32_t wirestack_http_files_upload_publish(
    uint64_t upload_handle,
    int64_t *out_native_code
) {
    if (out_native_code == NULL) {
        return WIRESTACK_HTTP_FILES_INVALID_ARGUMENT;
    }
    *out_native_code = 0;
    struct wirestack_http_files_upload *upload =
        (struct wirestack_http_files_upload *)(uintptr_t)upload_handle;
    if (upload == NULL || upload->magic != WIRESTACK_HTTP_FILES_UPLOAD_MAGIC ||
        upload->descriptor >= 0 || !upload->prepared) {
        return WIRESTACK_HTTP_FILES_CLOSED;
    }
    if (rename_without_replace(upload->root_descriptor, upload->temporary_name, upload->final_name) != 0) {
        return fail_errno(errno, out_native_code);
    }
    destroy_upload(upload, 0);
    return WIRESTACK_HTTP_FILES_OK;
}

void wirestack_http_files_upload_abort(uint64_t upload_handle) {
    struct wirestack_http_files_upload *upload =
        (struct wirestack_http_files_upload *)(uintptr_t)upload_handle;
    if (upload == NULL || upload->magic != WIRESTACK_HTTP_FILES_UPLOAD_MAGIC) {
        return;
    }
    destroy_upload(upload, 1);
}
