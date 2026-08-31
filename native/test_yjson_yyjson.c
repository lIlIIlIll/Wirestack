#include "yjson_yyjson.h"
#include "yjson_compact.h"

#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint64_t parse_ok(const char *text, uint32_t flags, uint32_t mode) {
    uint64_t handle = 0;
    uint32_t error = 0;
    int64_t offset = -1;
    int32_t status = YJ_Yyjson_Parse((const uint8_t *)text, (int64_t)strlen(text),
                                     flags, 256, mode, &handle, &error, &offset);
    if (status != YJ_COMPACT_OK) {
        fprintf(stderr, "parse failed status=%d error=%u offset=%lld flags=%u mode=%u text=%s\n",
                status, error, (long long)offset, flags, mode, text);
    }
    assert(status == YJ_COMPACT_OK);
    assert(error == YJ_COMPACT_OK);
    assert(handle != 0);
    return handle;
}

static void expect_error(const uint8_t *text, size_t length, uint32_t flags,
                         uint32_t expected) {
    uint64_t handle = 0;
    uint32_t error = 0;
    int64_t offset = -1;
    int32_t status = YJ_Yyjson_Parse(text, (int64_t)length, flags, 256,
                                     YJ_YYJSON_DIRECT, &handle, &error, &offset);
    assert(status == (int32_t)expected);
    assert(error == expected);
    assert(handle == 0);
    assert(offset >= 0 || expected == YJ_COMPACT_OUT_OF_MEMORY);
}

static void expect_limit(const char *text, int64_t max_bytes,
                         int64_t max_string_bytes, int64_t max_value_bytes,
                         uint32_t expected) {
    uint64_t handle = 0;
    uint32_t error = 0;
    int64_t offset = -1;
    int32_t status = YJ_Yyjson_ParseWithLimits(
        (const uint8_t *)text, (int64_t)strlen(text), 0, 256,
        YJ_YYJSON_DIRECT, max_bytes, max_string_bytes, max_value_bytes,
        &handle, &error, &offset);
    assert(status == (int32_t)expected);
    assert(error == expected);
    assert(handle == 0);
    assert(offset >= 0);
}

static char *serialize(uint64_t handle, uint64_t *size) {
    uint64_t buffer = 0;
    assert(YJ_Yyjson_SerializeAlloc(handle, &buffer, size) == YJ_COMPACT_OK);
    char *text = (char *)malloc((size_t)*size + 1u);
    assert(text != NULL);
    assert(YJ_Yyjson_CopyOwnedBuffer(buffer, (uint8_t *)text, *size) == YJ_COMPACT_OK);
    text[*size] = '\0';
    YJ_Yyjson_FreeOwnedBuffer(buffer);
    return text;
}

static void stats36(uint64_t handle, uint64_t stats[36]) {
    memset(stats, 0, 36u * sizeof(uint64_t));
    assert(YJ_Yyjson_Stats(handle, stats, 36) == YJ_COMPACT_OK);
}

static int32_t root_lookup_int(uint64_t handle, const char *key,
                               int64_t *out_value, uint32_t *out_found) {
    uint64_t root = 0, value_node = 0, inline_payload = 0;
    uint32_t inline_kind = UINT32_MAX;
    int32_t status = YJ_Yyjson_Root(handle, &root);
    if (status != YJ_COMPACT_OK) return status;
    status = YJ_Yyjson_ObjectLookup(handle, root, (const uint8_t *)key,
                                    strlen(key), &value_node, &inline_kind,
                                    &inline_payload, out_found);
    if (status != YJ_COMPACT_OK || *out_found == 0) return status;
    if (inline_kind == YJ_COMPACT_INT) {
        memcpy(out_value, &inline_payload, sizeof(*out_value));
        return YJ_COMPACT_OK;
    }
    return YJ_Yyjson_GetInt(handle, value_node, out_value);
}

static void test_modes_and_numbers(void) {
    const char *text = "{\"min\":-9223372036854775808,\"max\":9223372036854775807,"
                       "\"overflow\":9223372036854775808,\"decimal\":1.2300,\"exp\":1E-3,"
                       "\"s\":\"普通😀\",\"a\":[true,null]}";
    for (uint32_t mode = YJ_YYJSON_DIRECT; mode <= YJ_YYJSON_TRANSCODE; mode++) {
        uint64_t handle = parse_ok(text, YJ_YYJSON_PRESERVE_NUMBERS, mode);
        uint64_t root = 0, root_size = 0;
        assert(YJ_Yyjson_Root(handle, &root) == YJ_COMPACT_OK);
        assert(YJ_Yyjson_Size(handle, root, &root_size) == YJ_COMPACT_OK);
        assert(root_size == 7);
        int64_t value = 0;
        uint32_t found = 0;
        assert(root_lookup_int(handle, "min", &value, &found) == YJ_COMPACT_OK);
        assert(found == 1 && value == INT64_MIN);
        uint64_t size = 0;
        char *written = serialize(handle, &size);
        assert(strstr(written, "1.2300") != NULL);
        assert(strstr(written, "1E-3") != NULL);
        free(written);
        assert(YJ_Yyjson_TraversalChecksum(handle) != 0);
        YJ_Yyjson_Free(handle);
    }
}

static void test_number_strategies(void) {
    const char *mixed = "[0,-0,-9223372036854775808,9223372036854775807,"
                        "9223372036854775808,1.2300,1E-3]";
    uint64_t selective = parse_ok(mixed, 0, YJ_YYJSON_DIRECT);
    uint64_t stats[36];
    stats36(selective, stats);
    assert(stats[21] == 3); /* overflow, decimal, exponent */
    assert(stats[22] == strlen("9223372036854775808") + strlen("1.2300") + strlen("1E-3"));
    assert(stats[24] == strlen(mixed) + 1u);
    assert(stats[25] == 4 && stats[26] == 3);
    uint64_t written_size = 0;
    char *written = serialize(selective, &written_size);
    assert(strstr(written, "9223372036854775808") != NULL);
    assert(strstr(written, "1.2300") != NULL);
    assert(strstr(written, "1E-3") != NULL);
    free(written);
    YJ_Yyjson_Free(selective);

    uint64_t preserve = parse_ok(mixed, YJ_YYJSON_PRESERVE_NUMBERS, YJ_YYJSON_DIRECT);
    stats36(preserve, stats);
    assert(stats[21] == 7 && stats[24] == strlen(mixed) + 1u);
    written = serialize(preserve, &written_size);
    assert(strstr(written, "[0,-0,") != NULL);
    free(written);
    YJ_Yyjson_Free(preserve);

    uint64_t all_int = parse_ok("[1,2,3,-4]", YJ_YYJSON_NUMBER_DISPATCH_CUSTOM,
                                YJ_YYJSON_DIRECT);
    stats36(all_int, stats);
    assert(stats[11] == 0 && stats[24] == 0);
    YJ_Yyjson_Free(all_int);
    char dense[2048];
    size_t dense_at = 0;
    dense[dense_at++] = '[';
    for (int i = 0; i < 256; i++) {
        if (i != 0) dense[dense_at++] = ',';
        dense[dense_at++] = '1';
    }
    dense[dense_at++] = ']';
    dense[dense_at] = '\0';
    uint64_t dispatched = parse_ok(dense, YJ_YYJSON_NUMBER_DISPATCH_CUSTOM,
                                   YJ_YYJSON_DIRECT);
    stats36(dispatched, stats);
    assert(stats[11] == 0 && stats[8] == 256);
    YJ_Yyjson_Free(dispatched);

    dense[dense_at - 2] = '2';
    dense[dense_at - 1] = '.';
    dense[dense_at++] = '5';
    dense[dense_at++] = ']';
    dense[dense_at] = '\0';
    dispatched = parse_ok(dense, YJ_YYJSON_NUMBER_DISPATCH_CUSTOM,
                          YJ_YYJSON_DIRECT);
    stats36(dispatched, stats);
    assert(stats[11] == 1);
    YJ_Yyjson_Free(dispatched);

    uint64_t huge_exponent = parse_ok("1844674e07370", 0, YJ_YYJSON_DIRECT);
    written = serialize(huge_exponent, &written_size);
    assert(strcmp(written, "1844674e07370") == 0);
    free(written);
    YJ_Yyjson_Free(huge_exponent);

    uint64_t normalized_negative_zero = parse_ok("-0",
        YJ_YYJSON_NUMBER_DISPATCH_CUSTOM | YJ_YYJSON_NUMBER_LEGACY_RAW,
        YJ_YYJSON_DIRECT);
    written = serialize(normalized_negative_zero, &written_size);
    assert(strcmp(written, "0") == 0);
    free(written);
    YJ_Yyjson_Free(normalized_negative_zero);
}

static char *make_large_object(size_t fields) {
    size_t capacity = fields * 32u + 2u;
    char *text = (char *)malloc(capacity);
    assert(text != NULL);
    size_t at = 0;
    text[at++] = '{';
    for (size_t i = 0; i < fields; i++) {
        int count = snprintf(text + at, capacity - at, "%s\"k%zu\":%zu",
                             i == 0 ? "" : ",", i, i);
        assert(count > 0); at += (size_t)count;
    }
    text[at++] = '}'; text[at] = '\0';
    return text;
}

static void test_lookup_index_modes(void) {
    char *text = make_large_object(512);
    uint64_t stats[36];
    int64_t value = 0;
    uint32_t found = 0;
    uint64_t retained = parse_ok(text, YJ_YYJSON_RETAIN_ROOT_INDEX, YJ_YYJSON_DIRECT);
    stats36(retained, stats);
    assert(stats[27] != 0 && stats[28] == 1);
    assert(root_lookup_int(retained, "k511", &value, &found) == YJ_COMPACT_OK);
    assert(found == 1 && value == 511);
    assert(root_lookup_int(retained, "absent", &value, &found) == YJ_COMPACT_OK);
    assert(found == 0);
    YJ_Yyjson_Free(retained);

    uint64_t lazy = parse_ok(text, YJ_YYJSON_LAZY_ROOT_INDEX, YJ_YYJSON_DIRECT);
    stats36(lazy, stats);
    assert(stats[28] == 0);
    assert(root_lookup_int(lazy, "k256", &value, &found) == YJ_COMPACT_OK);
    assert(found == 1 && value == 256);
    stats36(lazy, stats);
    assert(stats[28] == 1 && stats[27] != 0);
    YJ_Yyjson_Free(lazy);
    free(text);
}

static void test_sequential_navigation_reuses_direct_cursors(void) {
    char *text = make_large_object(512);
    uint64_t handle = parse_ok(text, 0, YJ_YYJSON_DIRECT);
    uint64_t root = 0;
    assert(YJ_Yyjson_Root(handle, &root) == YJ_COMPACT_OK);
    YJ_Yyjson_TestResetNavigationRestarts();
    for (uint64_t index = 0; index < 512; index++) {
        uint64_t value = 0, payload = 0, key_size = 0, written = 0;
        uint32_t kind = UINT32_MAX;
        char key[32];
        assert(YJ_Yyjson_ObjectEntry(handle, root, index, &value, &kind,
                                     &payload, &key_size) == YJ_COMPACT_OK);
        assert(key_size < sizeof(key));
        assert(YJ_Yyjson_CopyObjectKey(handle, root, index, (uint8_t *)key,
                                       sizeof(key), &written) == YJ_COMPACT_OK);
        assert(written == key_size);
    }
    assert(YJ_Yyjson_TestNavigationRestarts() == 1);
    YJ_Yyjson_Free(handle);
    free(text);

    handle = parse_ok("[[0],[1],[2],[3],[4],[5],[6],[7]]", 0,
                      YJ_YYJSON_DIRECT);
    assert(YJ_Yyjson_Root(handle, &root) == YJ_COMPACT_OK);
    YJ_Yyjson_TestResetNavigationRestarts();
    for (uint64_t index = 0; index < 8; index++) {
        uint64_t child = 0;
        assert(YJ_Yyjson_ArrayGet(handle, root, index, &child) == YJ_COMPACT_OK);
        assert(child != 0);
    }
    assert(YJ_Yyjson_TestNavigationRestarts() == 1);
    YJ_Yyjson_Free(handle);
}

static void test_duplicates(void) {
    const char *duplicate = "{\"a\":1,\"\\u0061\":2}";
    uint64_t handle = parse_ok(duplicate, 0, YJ_YYJSON_DIRECT);
    int64_t value = 0;
    uint32_t found = 0;
    assert(root_lookup_int(handle, "a", &value, &found) == YJ_COMPACT_OK);
    assert(found == 1 && value == 2);
    uint64_t size = 0;
    char *written = serialize(handle, &size);
    assert(strcmp(written, "{\"a\":2}") == 0);
    free(written);
    uint64_t stats[12] = {0};
    assert(YJ_Yyjson_Stats(handle, stats, 12) == YJ_COMPACT_OK);
    assert(stats[11] == 1);
    YJ_Yyjson_Free(handle);
    expect_error((const uint8_t *)duplicate, strlen(duplicate),
                 YJ_YYJSON_REJECT_DUPLICATES, YJ_COMPACT_DUPLICATE_KEY);
}

static void test_errors(void) {
    static const uint8_t invalid_utf8[] = {'{','"','x','"',':','"',0xff,'"','}'};
    expect_error(invalid_utf8, sizeof(invalid_utf8), 0, YJ_COMPACT_INVALID_UTF8);
    expect_error((const uint8_t *)"[01]", 4, 0, YJ_COMPACT_PARSE_ERROR);
    expect_error((const uint8_t *)"[1]x", 4, 0, YJ_COMPACT_PARSE_ERROR);
    expect_error((const uint8_t *)"[1", 2, 0, YJ_COMPACT_PARSE_ERROR);
    expect_limit("{\"a\":1}", 6, 0, 0, YJ_COMPACT_DOCUMENT_TOO_LARGE);
    expect_limit("\"\\u4E2D\"", 0, 2, 0, YJ_COMPACT_STRING_TOO_LARGE);
    expect_limit("{\"a\":[1,2]}", 0, 0, 10, YJ_COMPACT_VALUE_TOO_LARGE);
}

static void test_close_loop(void) {
    for (int i = 0; i < 1000; i++) {
        uint64_t direct = parse_ok("{\"x\":1}", 0, YJ_YYJSON_DIRECT);
        uint64_t transcode = parse_ok("{\"x\":1}", 0, YJ_YYJSON_TRANSCODE);
        YJ_Yyjson_Free(direct);
        YJ_Yyjson_Free(transcode);
    }
}

int main(void) {
    test_modes_and_numbers();
    test_number_strategies();
    test_lookup_index_modes();
    test_sequential_navigation_reuses_direct_cursors();
    test_duplicates();
    test_errors();
    test_close_loop();
    puts("yjson yyjson targeted tests passed");
    return 0;
}
