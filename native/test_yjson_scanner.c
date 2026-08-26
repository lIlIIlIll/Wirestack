#include "yjson_scanner.h"

#include <assert.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static void test_skip_nested_value(void) {
    static const char text[] =
        "{\"ignored\":{\"array\":[1,{\"escaped\":\"a\\\"b\\\\c\\n\\t\\uD834\\uDD1E\"}],"
        "\"flag\":true},\"tail\":123}";
    int64_t end = -1, error = -1;
    assert(YJ_JSON_SkipValue((const uint8_t *)text, (int64_t)strlen(text), 0, 0,
                             &end, &error) == YJ_JSON_SCAN_OK);
    assert(end == (int64_t)strlen(text));
    assert(error == -1);
}

static void test_object_fields(void) {
    static const char text[] =
        "{\"unknown_value\":[1,2,3],\"user_id\":42,\"name\":\"Lin\",\"age\":28,"
        "\"tail\":{\"x\":1}}";
    uint64_t fields[5 * 8] = {0};
    int64_t end = -1, count = -1;
    assert(YJ_JSON_ScanObjectFields((const uint8_t *)text, (int64_t)strlen(text),
                                    0, 0, fields, 8, &end, &count) == YJ_JSON_SCAN_OK);
    assert(end == (int64_t)strlen(text));
    assert(count == 5);
    assert(fields[1] == strlen("unknown_value"));
    assert(memcmp(text + fields[0], "unknown_value", fields[1]) == 0);
    assert(fields[6] == strlen("user_id"));
    assert(memcmp(text + fields[5], "user_id", fields[6]) == 0);
    assert(fields[8] < fields[9]);
    assert((size_t)(fields[9] - fields[8]) == 2u);
    assert(memcmp(text + fields[8], "42", 2) == 0);
}

static void test_array_ranges(void) {
    static const char text[] =
        "[ {\"profile_id\":1,\"alias\":\"one\",\"level\":7},"
        " {\"profile_id\":2,\"alias\":\"two\",\"level\":8} ]";
    uint64_t elements[2 * 8] = {0};
    int64_t end = -1, count = -1;
    assert(YJ_JSON_ScanArrayElements((const uint8_t *)text, (int64_t)strlen(text),
                                     0, 0, elements, 8, &end, &count) == YJ_JSON_SCAN_OK);
    assert(end == (int64_t)strlen(text));
    assert(count == 2);
    assert(text[elements[0]] == '{' && text[elements[1] - 1] == '}');
    assert(text[elements[2]] == '{' && text[elements[3] - 1] == '}');
}

static void test_decode_escaped_string(void) {
    static const char text[] =
        "\"left\\\"mid\\\\line\\n\\t\\u4ed3\\u9889\\uD834\\uDD1Eright\"";
    static const uint8_t expected[] =
        "left\"mid\\line\n\t\xE4\xBB\x93\xE9\xA2\x89\xF0\x9D\x84\x9Eright";
    uint8_t output[128] = {0};
    int64_t end = -1, written = -1, error = -1;
    assert(YJ_JSON_DecodeString((const uint8_t *)text, (int64_t)strlen(text), 0,
                                YJ_JSON_SCAN_VALIDATE_STRINGS, output,
                                (int64_t)sizeof(output), &end, &written,
                                &error) == YJ_JSON_SCAN_OK);
    assert(end == (int64_t)strlen(text));
    assert(written == (int64_t)(sizeof(expected) - 1));
    assert(memcmp(output, expected, sizeof(expected) - 1) == 0);
}

static void test_validation_fallbacks(void) {
    static const uint8_t raw_utf8[] = {'"', 0xC3, 0xA9, '\\', 'n', '"'};
    uint8_t output[32] = {0};
    int64_t end = -1, written = -1, error = -1;
    assert(YJ_JSON_DecodeString(raw_utf8, (int64_t)sizeof(raw_utf8), 0,
                                YJ_JSON_SCAN_VALIDATE_STRINGS, output,
                                (int64_t)sizeof(output), &end, &written,
                                &error) == YJ_JSON_SCAN_FALLBACK);

    static const char lone_surrogate[] = "\"prefix\\uD834suffix\"";
    assert(YJ_JSON_DecodeString((const uint8_t *)lone_surrogate,
                                (int64_t)strlen(lone_surrogate), 0,
                                YJ_JSON_SCAN_VALIDATE_STRINGS, output,
                                (int64_t)sizeof(output), &end, &written,
                                &error) == YJ_JSON_SCAN_ERROR);
}

static void test_invalid_nested_boundaries(void) {
    static const char *invalid[] = {
        "\"\\uD834\"",
        "{\"a\":[1,]}",
        "{\"a\":{\"b\":1}"
    };
    for (size_t i = 0; i < sizeof(invalid) / sizeof(invalid[0]); i++) {
        int64_t end = -1, error = -1;
        assert(YJ_JSON_SkipValue((const uint8_t *)invalid[i],
                                 (int64_t)strlen(invalid[i]), 0, 0,
                                 &end, &error) == YJ_JSON_SCAN_ERROR);
        assert(error >= 0);
    }
}

static void test_nested_object_range(void) {
    static const char text[] =
        "{\"known\":1,\"unknown\":{\"array\":[1,{\"deep\":[true,false,null]}]},\"tail\":2}";
    uint64_t fields[5 * 8] = {0};
    int64_t end = -1, count = -1;
    assert(YJ_JSON_ScanObjectFields((const uint8_t *)text, (int64_t)strlen(text),
                                    0, 0, fields, 8, &end, &count) == YJ_JSON_SCAN_OK);
    assert(count == 3);
    assert(text[fields[8]] == '{');
    assert(text[fields[9] - 1] == '}');
}

static void test_many_element_plan(void) {
    char text[2048];
    size_t at = 0;
    text[at++] = '[';
    for (int i = 0; i < 16; i++) {
        int written = snprintf(text + at, sizeof(text) - at,
                               "%s{\"profile_id\":%d,\"alias\":\"item-%d\",\"level\":7}",
                               i == 0 ? "" : ",", i, i);
        assert(written > 0);
        at += (size_t)written;
    }
    text[at++] = ']';
    text[at] = '\0';
    uint64_t elements[2 * 16] = {0};
    int64_t end = -1, count = -1;
    assert(YJ_JSON_ScanArrayElements((const uint8_t *)text, (int64_t)at, 0, 0,
                                     elements, 16, &end, &count) == YJ_JSON_SCAN_OK);
    assert(count == 16 && end == (int64_t)at);
}

static void test_parse_double_token(void) {
    static const char text[] = "1.5,-0.0,1e308,1e-323,1.";
    assert(YJ_JSON_ParseDouble((const uint8_t *)text, (int64_t)strlen(text),
                               0, 3) == 1.5);
    double negative_zero = YJ_JSON_ParseDouble((const uint8_t *)text,
                                                (int64_t)strlen(text), 4, 4);
    assert(negative_zero == 0.0 && signbit(negative_zero));
    assert(isfinite(YJ_JSON_ParseDouble((const uint8_t *)text,
                                         (int64_t)strlen(text), 9, 5)));
    assert(YJ_JSON_ParseDouble((const uint8_t *)text, (int64_t)strlen(text),
                               15, 6) > 0.0);
    assert(isnan(YJ_JSON_ParseDouble((const uint8_t *)text,
                                     (int64_t)strlen(text), 0, 4)));
    assert(isnan(YJ_JSON_ParseDouble((const uint8_t *)text,
                                     (int64_t)strlen(text), 0, 257)));
}

static void test_escape_string_token(void) {
    static const uint8_t input[] = "left\n\"\\<中";
    static const uint8_t expected[] = "\"left\\n\\\"\\\\<中\"";
    static const uint8_t html_expected[] = "\"left\\n\\\"\\\\\\u003c中\"";
    uint8_t output[128] = {0};
    int64_t written = -1;
    assert(YJ_JSON_EscapeString(input, (int64_t)(sizeof(input) - 1), 0,
                                output, (int64_t)sizeof(output), &written) == YJ_JSON_SCAN_OK);
    assert(written == (int64_t)(sizeof(expected) - 1));
    assert(memcmp(output, expected, sizeof(expected) - 1) == 0);
    assert(YJ_JSON_EscapeString(input, (int64_t)(sizeof(input) - 1), 1,
                                output, (int64_t)sizeof(output), &written) == YJ_JSON_SCAN_OK);
    assert(written == (int64_t)(sizeof(html_expected) - 1));
    assert(memcmp(output, html_expected, sizeof(html_expected) - 1) == 0);
    assert(YJ_JSON_EscapeString(input, (int64_t)(sizeof(input) - 1), 0,
                                output, 2, &written) == YJ_JSON_SCAN_CAPACITY);
}

int main(void) {
    test_skip_nested_value();
    test_object_fields();
    test_array_ranges();
    test_decode_escaped_string();
    test_validation_fallbacks();
    test_invalid_nested_boundaries();
    test_nested_object_range();
    test_many_element_plan();
    test_parse_double_token();
    test_escape_string_token();
    puts("yjson scanner targeted tests passed");
    return 0;
}
