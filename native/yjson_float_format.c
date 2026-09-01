#define yyjson_api static
#include "vendor/yyjson/yyjson.c"

#include "yjson_scanner.h"

int32_t YJ_JSON_FormatFloat64Array(const double* values, int64_t count,
    uint8_t* output, int64_t outputCap, int64_t outputOffset,
    int64_t* outWritten)
{
    if (values == NULL || output == NULL || outWritten == NULL || count < 0 ||
        outputOffset < 0 || outputOffset > outputCap ||
        outputCap - outputOffset < 2) {
        return YJ_JSON_SCAN_ERROR;
    }
    output += outputOffset;
    outputCap -= outputOffset;
    int64_t written = 0;
    output[written++] = '[';
    for (int64_t index = 0; index < count; ++index) {
        if (!isfinite(values[index])) {
            return YJ_JSON_SCAN_ERROR;
        }
        if (index > 0) {
            if (written >= outputCap) return YJ_JSON_SCAN_CAPACITY;
            output[written++] = ',';
        }
        if (outputCap - written < 40) return YJ_JSON_SCAN_CAPACITY;
        u64 bits;
        memcpy(&bits, &values[index], sizeof(bits));
        uint8_t* end = write_f64_raw(output + written, bits, 0);
        written += (int64_t)(end - (output + written));
    }
    if (written >= outputCap) return YJ_JSON_SCAN_CAPACITY;
    output[written++] = ']';
    *outWritten = written;
    return YJ_JSON_SCAN_OK;
}
