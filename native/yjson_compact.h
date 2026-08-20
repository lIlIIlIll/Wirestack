#ifndef YJSON_COMPACT_H
#define YJSON_COMPACT_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    YJ_COMPACT_OK = 0,
    YJ_COMPACT_PARSE_ERROR = 1,
    YJ_COMPACT_INVALID_UTF8 = 2,
    YJ_COMPACT_MAX_DEPTH = 3,
    YJ_COMPACT_DUPLICATE_KEY = 4,
    YJ_COMPACT_OUT_OF_MEMORY = 5,
    YJ_COMPACT_DOCUMENT_TOO_LARGE = 6,
    YJ_COMPACT_CLOSED = 7,
    YJ_COMPACT_TYPE_ERROR = 8,
    YJ_COMPACT_BOUNDS_ERROR = 9,
    YJ_COMPACT_STRING_TOO_LARGE = 10,
    YJ_COMPACT_VALUE_TOO_LARGE = 11
};

enum {
    YJ_COMPACT_NULL = 0,
    YJ_COMPACT_BOOL = 1,
    YJ_COMPACT_INT = 2,
    YJ_COMPACT_NUMBER = 3,
    YJ_COMPACT_STRING = 4,
    YJ_COMPACT_ARRAY = 5,
    YJ_COMPACT_OBJECT = 6
};

enum {
    YJ_COMPACT_REJECT_DUPLICATES = 1u,
    YJ_COMPACT_PRESERVE_NUMBERS = 2u,
    YJ_COMPACT_MATERIALIZE_SOURCE = 4u,
    YJ_COMPACT_DUPLICATE_LOAD_50 = 8u,
    YJ_COMPACT_DUPLICATE_LOAD_625 = 16u,
    YJ_COMPACT_DUPLICATE_LOAD_875 = 32u,
    YJ_COMPACT_DUPLICATE_PRESIZE = 64u,
    YJ_COMPACT_DUPLICATE_STATS = 128u
};

/*
 * All handles are process-local opaque uintptr_t values represented as
 * uint64_t.  The ABI is intentionally additive to the existing scanner ABI.
 * Parsing borrows input only for this call and copies it before returning.
 */
int32_t YJ_Compact_Parse(const uint8_t *input, int64_t length,
                        uint32_t flags, int64_t max_depth,
                        uint64_t *out_handle, uint32_t *out_root,
                        uint32_t *out_error_code, int64_t *out_error_offset);
/* Additive resource-limited entry point. Zero limits mean unlimited. */
int32_t YJ_Compact_ParseWithLimits(const uint8_t *input, int64_t length,
                                  uint32_t flags, int64_t max_depth,
                                  int64_t max_bytes, int64_t max_string_bytes,
                                  int64_t max_value_bytes,
                                  uint64_t *out_handle, uint32_t *out_root,
                                  uint32_t *out_error_code,
                                  int64_t *out_error_offset);

/* Allocation-free validation bridge shared by native JSON backends. */
int32_t YJ_JSON_ValidateLimits(const uint8_t *input, int64_t length,
                              int64_t max_depth, int64_t max_bytes,
                              int64_t max_string_bytes,
                              int64_t max_value_bytes,
                              uint32_t *out_error_code,
                              int64_t *out_error_offset);
void YJ_Compact_Free(uint64_t handle);

int32_t YJ_Compact_Kind(uint64_t handle, uint32_t node, uint32_t *out_kind);
int32_t YJ_Compact_Size(uint64_t handle, uint32_t node, uint64_t *out_size);
int32_t YJ_Compact_GetInt(uint64_t handle, uint32_t node, int64_t *out_value);
int32_t YJ_Compact_GetBool(uint64_t handle, uint32_t node, uint32_t *out_value);
int32_t YJ_Compact_GetTextSize(uint64_t handle, uint32_t node, uint64_t *out_size);
int32_t YJ_Compact_CopyText(uint64_t handle, uint32_t node,
                           uint8_t *output, uint64_t output_capacity,
                           uint64_t *out_written);
int32_t YJ_Compact_ArrayGet(uint64_t handle, uint32_t node,
                           uint64_t index, uint32_t *out_node);
int32_t YJ_Compact_ObjectEntry(uint64_t handle, uint32_t node, uint64_t index,
                              uint32_t *out_value_kind, uint64_t *out_value_payload,
                              uint64_t *out_key_size);
int32_t YJ_Compact_CopyObjectKey(uint64_t handle, uint32_t node, uint64_t index,
                                uint8_t *output, uint64_t output_capacity,
                                uint64_t *out_written);
int32_t YJ_Compact_ObjectLookup(uint64_t handle, uint32_t node,
                               const uint8_t *key, uint64_t key_length,
                               uint32_t *out_value_kind, uint64_t *out_value_payload,
                               uint32_t *out_found);
int32_t YJ_Compact_GetStringRefSize(uint64_t handle, uint64_t string_ref,
                                   uint64_t *out_size);
int32_t YJ_Compact_CopyStringRef(uint64_t handle, uint64_t string_ref,
                                uint8_t *output, uint64_t output_capacity,
                                uint64_t *out_written);

uint64_t YJ_Compact_TraversalChecksum(uint64_t handle);
int32_t YJ_Compact_Serialize(uint64_t handle, uint8_t *output,
                            uint64_t output_capacity, uint64_t *out_written);
int32_t YJ_Compact_SerializeAlloc(uint64_t handle, uint64_t *out_buffer_handle,
                                 uint64_t *out_size);
int32_t YJ_Compact_ExportTapeAlloc(uint64_t handle, uint64_t *out_buffer_handle,
                                  uint64_t *out_size);
int32_t YJ_Compact_CopyOwnedBuffer(uint64_t buffer_handle, uint8_t *output,
                                  uint64_t output_capacity);
void YJ_Compact_FreeOwnedBuffer(uint64_t buffer_handle);

/* stats[0..11]: source, persistent used/committed, arena used/committed,
 * scratch current/peak, duplicate scratch peak, node count, object fields,
 * array entries, string refs. */
int32_t YJ_Compact_Stats(uint64_t handle, uint64_t *stats, uint64_t capacity);

/* duplicate_stats[0..15]: lookups, inserts, probes, exact equalities,
 * max probe, grow count, rehashed entries, final/largest capacity,
 * p50/p95/p99 probe, occupied slots, load ppm, presized, reserved. */
int32_t YJ_Compact_DuplicateStats(uint64_t handle, uint64_t *stats,
                                 uint64_t capacity);

/* Credential-free FFI cost probes used only by the benchmark runner. */
uint64_t YJ_Compact_Noop(uint64_t value);
int32_t YJ_Compact_ScalarProbe(uint64_t value, uint64_t *out_value);
int32_t YJ_Compact_CopyProbe(const uint8_t *input, uint64_t length,
                            uint64_t iterations, uint64_t *out_checksum);

#ifdef __cplusplus
}
#endif

#endif
