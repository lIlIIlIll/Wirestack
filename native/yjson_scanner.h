#ifndef YJSON_REFLECT_SCANNER_H
#define YJSON_REFLECT_SCANNER_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define YJ_JSON_SCAN_OK 0
#define YJ_JSON_SCAN_FALLBACK 1
#define YJ_JSON_SCAN_CAPACITY 2
#define YJ_JSON_SCAN_ERROR (-1)

#define YJ_JSON_SCAN_VALIDATE_STRINGS 1u

uint32_t YJ_JSON_SimdCaps(void);

int32_t YJ_JSON_SkipValue(
    const uint8_t* input, int64_t len, int64_t start, uint32_t flags,
    int64_t* outEnd, int64_t* outError);

int32_t YJ_JSON_ScanTape(
    const uint8_t* input, int64_t len, int64_t start, uint32_t flags,
    uint64_t* tokens, int64_t tokenCap,
    int64_t* outNext, int64_t* outError);

int32_t YJ_JSON_ScanString(
    const uint8_t* input, int64_t len, int64_t start, uint32_t flags,
    int64_t* outEnd, int64_t* outError);

int32_t YJ_JSON_DecodeString(
    const uint8_t* input, int64_t len, int64_t start, uint32_t flags,
    uint8_t* output, int64_t outputCap,
    int64_t* outEnd, int64_t* outWritten, int64_t* outError);

int32_t YJ_JSON_ScanObjectFields(
    const uint8_t* input, int64_t len, int64_t start, uint32_t flags,
    uint64_t* fields, int64_t fieldCap,
    int64_t* outEnd, int64_t* outError);

int32_t YJ_JSON_ScanArrayElements(
    const uint8_t* input, int64_t len, int64_t start, uint32_t flags,
    uint64_t* elements, int64_t elementCap,
    int64_t* outEnd, int64_t* outError);

/*
 * Scans a numeric-array segment in bulk. `start` points at the next number or
 * the closing bracket (the opening bracket is consumed by the caller). Each
 * token occupies four words: start, end, small unsigned magnitude, flags.
 * Flags: bit 0 negative, bit 1 exponent, bit 2 small-unscaled-valid, and bits
 * 8..39 fractional scale. The function consumes the following comma and
 * whitespace when another chunk is required, so `outNext` is resumable without
 * rescanning. On YJ_JSON_SCAN_FALLBACK, completed numeric tokens are committed,
 * `outNext` points at the first byte of the unconsumed non-numeric value, and
 * the generic parser can continue without reading the numeric prefix again.
 * Invalid number-shaped input returns YJ_JSON_SCAN_ERROR, never FALLBACK.
 * `outDone` is one only after consuming the closing bracket.
 */
int32_t YJ_JSON_ScanNumericArrayChunk(
    const uint8_t* input, int64_t len, int64_t start, uint32_t flags,
    uint64_t* tokens, int64_t tokenCap,
    int64_t* outNext, int64_t* outCount, int64_t* outDone, int64_t* outError);

/*
 * Finds number tokens across arbitrary JSON structure in a bounded input page.
 * The caller owns and reuses `tokens`; every token uses the same four-word
 * layout as YJ_JSON_ScanNumericArrayChunk. Strings are skipped with
 * quote and escape awareness. Grammar and DOM construction remain with the caller.
 */
int32_t YJ_JSON_ScanNumericTape(
    const uint8_t* input, int64_t len, int64_t start, int64_t pageBytes,
    uint32_t flags, uint64_t* tokens, int64_t tokenCap,
    int64_t* outNext, int64_t* outCount, int64_t* outError);

#ifdef __cplusplus
}
#endif

#endif
