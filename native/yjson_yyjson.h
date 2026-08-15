#ifndef YJSON_YYJSON_H
#define YJSON_YYJSON_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    YJ_YYJSON_DIRECT = 0,
    YJ_YYJSON_TRANSCODE = 1
};

enum {
    YJ_YYJSON_REJECT_DUPLICATES = 1u,
    YJ_YYJSON_PRESERVE_NUMBERS = 2u,
    /* Qualification controls for the compact number/index strategies. */
    YJ_YYJSON_NUMBER_DISPATCH_CUSTOM = 4u,
    YJ_YYJSON_NUMBER_LEGACY_RAW = 8u,
    YJ_YYJSON_RETAIN_ROOT_INDEX = 16u,
    YJ_YYJSON_LAZY_ROOT_INDEX = 32u,
    /* Benchmark qualification control; production uses the fused pass. */
    YJ_YYJSON_SEPARATE_VALIDATION = 64u
};

/*
 * Optional yyjson 0.12.0 semantic adapter. Parsing borrows input only for the
 * duration of this coarse call. The returned handle owns either the yyjson DOM
 * (direct mode) or a transcode-owned POD document (transcode mode).
 */
int32_t YJ_Yyjson_Parse(const uint8_t *input, int64_t length,
                       uint32_t flags, int64_t max_depth, uint32_t mode,
                       uint64_t *out_handle, uint32_t *out_error_code,
                       int64_t *out_error_offset);
void YJ_Yyjson_Free(uint64_t handle);

uint64_t YJ_Yyjson_TraversalChecksum(uint64_t handle);
int32_t YJ_Yyjson_RootSize(uint64_t handle, uint64_t *out_size);
int32_t YJ_Yyjson_ObjectLookupInt(uint64_t handle,
                                 const uint8_t *key, uint64_t key_length,
                                 int64_t *out_value, uint32_t *out_found);

int32_t YJ_Yyjson_SerializeAlloc(uint64_t handle,
                                uint64_t *out_buffer_handle,
                                uint64_t *out_size);
int32_t YJ_Yyjson_CopyOwnedBuffer(uint64_t buffer_handle,
                                 uint8_t *output,
                                 uint64_t output_capacity);
void YJ_Yyjson_FreeOwnedBuffer(uint64_t buffer_handle);

/* stats[0..35]: allocator current/peak/total, validation scratch peak,
 * persistent used/committed, node/object/array/string counts, mode, fallback,
 * validation/index/number-strategy counters. */
int32_t YJ_Yyjson_Stats(uint64_t handle, uint64_t *stats, uint64_t capacity);

#if defined(YJ_TESTING)
/* Test-only proof that the adapter is bound to its vendored yyjson build. */
uint32_t YJ_Yyjson_TestVendoredVersion(void);
#endif

#ifdef __cplusplus
}
#endif

#endif
