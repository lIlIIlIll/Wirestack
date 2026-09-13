#ifndef WIRESTACK_HTTP_FILES_H
#define WIRESTACK_HTTP_FILES_H

#include <stdint.h>

#if defined(__cplusplus)
extern "C" {
#endif

enum wirestack_http_files_status {
    WIRESTACK_HTTP_FILES_OK = 0,
    WIRESTACK_HTTP_FILES_INVALID_ARGUMENT = 1,
    WIRESTACK_HTTP_FILES_OUT_OF_MEMORY = 2,
    WIRESTACK_HTTP_FILES_NOT_FOUND = 3,
    WIRESTACK_HTTP_FILES_PERMISSION_DENIED = 4,
    WIRESTACK_HTTP_FILES_SYMLINK_REJECTED = 5,
    WIRESTACK_HTTP_FILES_NONREGULAR = 6,
    WIRESTACK_HTTP_FILES_LIMIT_EXCEEDED = 7,
    WIRESTACK_HTTP_FILES_ALREADY_EXISTS = 8,
    WIRESTACK_HTTP_FILES_CLOSED = 9,
    WIRESTACK_HTTP_FILES_FILE_CHANGED = 10,
    WIRESTACK_HTTP_FILES_SYSTEM_FAILURE = 11
};

uint32_t wirestack_http_files_abi_version(void);

int32_t wirestack_http_files_root_open(
    const uint8_t *path,
    uint64_t path_size,
    uint64_t *out_root_handle,
    int64_t *out_native_code
);

void wirestack_http_files_root_close(uint64_t root_handle);

int32_t wirestack_http_files_download_open(
    uint64_t root_handle,
    const uint8_t *relative_path,
    uint64_t relative_path_size,
    uint64_t maximum_bytes,
    uint64_t *out_file_handle,
    uint64_t *out_file_size,
    int64_t *out_native_code
);

int32_t wirestack_http_files_file_read(
    uint64_t file_handle,
    uint8_t *output,
    uint64_t output_capacity,
    uint64_t *out_count,
    int64_t *out_native_code
);

void wirestack_http_files_file_close(uint64_t file_handle);

int32_t wirestack_http_files_upload_begin(
    uint64_t root_handle,
    const uint8_t *filename,
    uint64_t filename_size,
    uint64_t maximum_bytes,
    uint64_t *out_upload_handle,
    int64_t *out_native_code
);

int32_t wirestack_http_files_upload_write(
    uint64_t upload_handle,
    const uint8_t *input,
    uint64_t input_size,
    int64_t *out_native_code
);

int32_t wirestack_http_files_upload_prepare(
    uint64_t upload_handle,
    int64_t *out_native_code
);

int32_t wirestack_http_files_upload_publish(
    uint64_t upload_handle,
    int64_t *out_native_code
);

void wirestack_http_files_upload_abort(uint64_t upload_handle);

#if defined(__cplusplus)
}
#endif

#endif
