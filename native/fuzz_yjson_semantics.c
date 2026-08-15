#include "yjson_compact.h"
#include "yjson_yyjson.h"
#include "vendor/yyjson/yyjson.h"

#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint8_t *custom_serialize(uint64_t handle, uint64_t *size) {
    uint64_t buffer = 0;
    if (YJ_Compact_SerializeAlloc(handle, &buffer, size) != YJ_COMPACT_OK)
        return NULL;
    uint8_t *data = (uint8_t *)malloc((size_t)*size + 1u);
    if (data == NULL || YJ_Compact_CopyOwnedBuffer(buffer, data, *size) !=
                        YJ_COMPACT_OK) {
        free(data); data = NULL;
    } else data[*size] = 0;
    YJ_Compact_FreeOwnedBuffer(buffer);
    return data;
}

static uint8_t *yy_serialize(uint64_t handle, uint64_t *size) {
    uint64_t buffer = 0;
    if (YJ_Yyjson_SerializeAlloc(handle, &buffer, size) != YJ_COMPACT_OK)
        return NULL;
    uint8_t *data = (uint8_t *)malloc((size_t)*size + 1u);
    if (data == NULL || YJ_Yyjson_CopyOwnedBuffer(buffer, data, *size) !=
                        YJ_COMPACT_OK) {
        free(data); data = NULL;
    } else data[*size] = 0;
    YJ_Yyjson_FreeOwnedBuffer(buffer);
    return data;
}

static int semantic_equal(const uint8_t *left, uint64_t left_size,
                          const uint8_t *right, uint64_t right_size) {
    yyjson_doc *lhs = yyjson_read_opts((char *)(uintptr_t)left,
        (size_t)left_size, YYJSON_READ_NUMBER_AS_RAW, NULL, NULL);
    yyjson_doc *rhs = yyjson_read_opts((char *)(uintptr_t)right,
        (size_t)right_size, YYJSON_READ_NUMBER_AS_RAW, NULL, NULL);
    int equal = lhs != NULL && rhs != NULL &&
        yyjson_equals(yyjson_doc_get_root(lhs), yyjson_doc_get_root(rhs));
    if (lhs != NULL) yyjson_doc_free(lhs);
    if (rhs != NULL) yyjson_doc_free(rhs);
    return equal;
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    if (size == 0 || size > INT64_MAX) return 0;
    uint64_t custom = 0, adapter = 0;
    uint32_t custom_root = 0, custom_error = 0, adapter_error = 0;
    int64_t custom_offset = -1, adapter_offset = -1;
    int32_t custom_status = YJ_Compact_Parse(data, (int64_t)size, 0, 256,
        &custom, &custom_root, &custom_error, &custom_offset);
    int32_t adapter_status = YJ_Yyjson_Parse(data, (int64_t)size,
        YJ_YYJSON_RETAIN_ROOT_INDEX | YJ_YYJSON_NUMBER_DISPATCH_CUSTOM |
        YJ_YYJSON_NUMBER_LEGACY_RAW, 256, YJ_YYJSON_DIRECT,
        &adapter, &adapter_error, &adapter_offset);
    if ((custom_status == YJ_COMPACT_OK) != (adapter_status == YJ_COMPACT_OK)) {
        fprintf(stderr, "status mismatch custom=%d adapter=%d size=%zu input=",
                custom_status, adapter_status, size);
        fwrite(data, 1, size, stderr); fputc('\n', stderr);
        abort();
    }
    if (custom_status == YJ_COMPACT_OK) {
        uint64_t custom_size = 0, adapter_size = 0;
        uint8_t *custom_json = custom_serialize(custom, &custom_size);
        uint8_t *adapter_json = yy_serialize(adapter, &adapter_size);
        if (custom_json == NULL || adapter_json == NULL ||
            !semantic_equal(custom_json, custom_size, adapter_json, adapter_size)) {
            fprintf(stderr, "semantic mismatch size=%zu input=", size);
            fwrite(data, 1, size, stderr); fputc('\n', stderr);
            if (custom_json != NULL) {
                fprintf(stderr, "custom="); fwrite(custom_json, 1, custom_size, stderr);
                fputc('\n', stderr);
            }
            if (adapter_json != NULL) {
                fprintf(stderr, "adapter="); fwrite(adapter_json, 1, adapter_size, stderr);
                fputc('\n', stderr);
            }
            abort();
        }
        free(custom_json);
        free(adapter_json);
    }
    if (custom != 0) YJ_Compact_Free(custom);
    if (adapter != 0) YJ_Yyjson_Free(adapter);
    return 0;
}

#if defined(YJ_FUZZ_STANDALONE)
static uint64_t next_random(uint64_t *state) {
    uint64_t value = *state;
    value ^= value << 13; value ^= value >> 7; value ^= value << 17;
    *state = value;
    return value;
}

int main(int argc, char **argv) {
    uint64_t iterations = argc > 1 ? strtoull(argv[1], NULL, 10) : 50000u;
    static const char *seeds[] = {
        "null", "true", "false", "0", "-0", "9223372036854775807",
        "9223372036854775808", "18446744073709551615", "1.2300", "1E-3",
        "[0,-1,1.0,1e3,9223372036854775808]",
        "{\"a\":1,\"b\":[true,null,\"x\"]}",
        "{\"a\":1,\"\\u0061\":2}",
        "{\"普通\":\"😀\",\"x\\\\y\":3}",
        "[[[[0]]]]", "{\"truncated\":", "[1,]", "{\"x\":01}"
    };
    uint64_t state = UINT64_C(0x6a09e667f3bcc909);
    static const char mutation_chars[] = "{}[],:\"\\-019eE tfn";
    uint8_t buffer[4096];
    for (uint64_t i = 0; i < iterations; i++) {
        const char *seed = seeds[next_random(&state) %
            (sizeof(seeds) / sizeof(seeds[0]))];
        size_t size = strlen(seed);
        memcpy(buffer, seed, size);
        uint64_t mutations = 1u + next_random(&state) % 4u;
        for (uint64_t j = 0; j < mutations && size != 0; j++) {
            size_t at = (size_t)(next_random(&state) % size);
            switch (next_random(&state) % 4u) {
                case 0: buffer[at] ^= (uint8_t)(1u << (next_random(&state) & 7u)); break;
                case 1: buffer[at] = (uint8_t)mutation_chars[
                    next_random(&state) % (sizeof(mutation_chars) - 1u)]; break;
                case 2: size = at; break;
                default:
                    if (size + 1u < sizeof(buffer)) buffer[size++] = buffer[at];
                    break;
            }
        }
        LLVMFuzzerTestOneInput(buffer, size);
    }
    printf("yjson semantic differential cases=%llu\n",
           (unsigned long long)iterations);
    return 0;
}
#endif
