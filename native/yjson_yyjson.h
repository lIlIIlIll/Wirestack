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
/* Additive resource-limited entry point. Zero limits mean unlimited. */
int32_t YJ_Yyjson_ParseWithLimits(const uint8_t *input, int64_t length,
                                 uint32_t flags, int64_t max_depth,
                                 uint32_t mode, int64_t max_bytes,
                                 int64_t max_string_bytes,
                                 int64_t max_value_bytes,
                                 uint64_t *out_handle,
                                 uint32_t *out_error_code,
                                 int64_t *out_error_offset);
void YJ_Yyjson_Free(uint64_t handle);

uint64_t YJ_Yyjson_TraversalChecksum(uint64_t handle);
/* Generic read-only value ABI. A node token is document-local and remains
 * valid only while the document handle is open. Object scalar values may be
 * returned inline; UINT32_MAX in out_inline_kind means out_node is used. */
int32_t YJ_Yyjson_Root(uint64_t handle, uint64_t *out_node);
int32_t YJ_Yyjson_Kind(uint64_t handle, uint64_t node, uint32_t *out_kind);
int32_t YJ_Yyjson_Size(uint64_t handle, uint64_t node, uint64_t *out_size);
int32_t YJ_Yyjson_GetInt(uint64_t handle, uint64_t node, int64_t *out_value);
int32_t YJ_Yyjson_GetBool(uint64_t handle, uint64_t node, uint32_t *out_value);
int32_t YJ_Yyjson_GetTextSize(uint64_t handle, uint64_t node,
                             uint64_t *out_size);
int32_t YJ_Yyjson_CopyText(uint64_t handle, uint64_t node,
                          uint8_t *output, uint64_t output_capacity,
                          uint64_t *out_written);
int32_t YJ_Yyjson_GetInlineTextSize(uint64_t handle, uint64_t reference,
                                   uint64_t *out_size);
int32_t YJ_Yyjson_CopyInlineText(uint64_t handle, uint64_t reference,
                                uint8_t *output, uint64_t output_capacity,
                                uint64_t *out_written);
int32_t YJ_Yyjson_ArrayGet(uint64_t handle, uint64_t node, uint64_t index,
                          uint64_t *out_node);
int32_t YJ_Yyjson_ObjectEntry(uint64_t handle, uint64_t node, uint64_t index,
                             uint64_t *out_value_node,
                             uint32_t *out_inline_kind,
                             uint64_t *out_inline_payload,
                             uint64_t *out_key_size);
int32_t YJ_Yyjson_CopyObjectKey(uint64_t handle, uint64_t node,
                               uint64_t index, uint8_t *output,
                               uint64_t output_capacity,
                               uint64_t *out_written);
int32_t YJ_Yyjson_ObjectLookup(uint64_t handle, uint64_t node,
                              const uint8_t *key, uint64_t key_length,
                              uint64_t *out_value_node,
                              uint32_t *out_inline_kind,
                              uint64_t *out_inline_payload,
                              uint32_t *out_found);

int32_t YJ_Yyjson_SerializeAlloc(uint64_t handle,
                                uint64_t *out_buffer_handle,
                                uint64_t *out_size);
/* Matching-version typed-stream bridge using the shared YJT1 preorder tape. */
int32_t YJ_Yyjson_ExportTapeAlloc(uint64_t handle,
                                 uint64_t *out_buffer_handle,
                                 uint64_t *out_size);
int32_t YJ_Yyjson_EncodeTapeAlloc(const uint8_t *tape, uint64_t tape_length,
                                 const uint8_t *newline, uint64_t newline_length,
                                 const uint8_t *indent, uint64_t indent_length,
                                 uint32_t use_space_after_separators,
                                 uint32_t html_safe, int64_t max_depth,
                                 int64_t max_bytes, uint64_t *out_buffer_handle,
                                 uint64_t *out_size, uint32_t *out_error_code);
int32_t YJ_Yyjson_CopyOwnedBuffer(uint64_t buffer_handle,
                                 uint8_t *output,
                                 uint64_t output_capacity);
void YJ_Yyjson_FreeOwnedBuffer(uint64_t buffer_handle);

/* stats[0..35]: allocator current/peak/total, validation scratch peak,
 * persistent used/committed, node/object/array/string counts, mode, fallback,
 * validation/index/number-strategy counters. */
int32_t YJ_Yyjson_Stats(uint64_t handle, uint64_t *stats, uint64_t capacity);

#if defined(YJ_TESTING)
void YJ_Yyjson_TestResetNavigationRestarts(void);
uint64_t YJ_Yyjson_TestNavigationRestarts(void);
/* Test-only proof that the adapter is bound to its vendored yyjson build. */
uint32_t YJ_Yyjson_TestVendoredVersion(void);
#endif

#ifdef __cplusplus
}
#endif

#endif
