#include "yjson_yyjson.h"
#include "vendor/yyjson/yyjson.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
    static const uint8_t input[] = "{\"value\":42}";
    uint32_t expected_adapter;
    uint32_t expected_consumer;
    uint64_t handle = 0;
    uint32_t error_code = 0;
    int64_t error_offset = 0;

    if (argc != 3) {
        fprintf(stderr, "usage: %s EXPECTED_ADAPTER EXPECTED_CONSUMER\n", argv[0]);
        return 2;
    }
    expected_adapter = (uint32_t)strtoul(argv[1], NULL, 0);
    expected_consumer = (uint32_t)strtoul(argv[2], NULL, 0);

    if (YJ_Yyjson_TestVendoredVersion() != expected_adapter) {
        fprintf(stderr, "adapter yyjson version: got=0x%06x expected=0x%06x\n",
                YJ_Yyjson_TestVendoredVersion(), expected_adapter);
        return 1;
    }
    if (yyjson_version() != expected_consumer) {
        fprintf(stderr, "consumer yyjson version: got=0x%06x expected=0x%06x\n",
                yyjson_version(), expected_consumer);
        return 1;
    }
    if (YJ_Yyjson_Parse(input, (int64_t)(sizeof(input) - 1u), 0, 128,
                        YJ_YYJSON_DIRECT, &handle, &error_code,
                        &error_offset) != 0) {
        fprintf(stderr, "yjson parse failed: code=%u offset=%lld\n",
                error_code, (long long)error_offset);
        return 1;
    }
    YJ_Yyjson_Free(handle);
    printf("colink passed adapter=0x%06x consumer=0x%06x\n",
           expected_adapter, expected_consumer);
    return 0;
}
