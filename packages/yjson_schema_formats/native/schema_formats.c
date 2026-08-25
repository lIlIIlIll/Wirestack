#include <idn2.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

static uint32_t yj_schema_next_utf8(const uint8_t *input, int64_t length, int64_t *index) {
    uint8_t first = input[(*index)++];
    if (first < 0x80) return first;
    if ((first & 0xe0) == 0xc0 && *index < length)
        return ((uint32_t)(first & 0x1f) << 6) | (input[(*index)++] & 0x3f);
    if ((first & 0xf0) == 0xe0 && *index + 1 < length) {
        uint32_t value = ((uint32_t)(first & 0x0f) << 12) |
            ((uint32_t)(input[(*index)++] & 0x3f) << 6);
        return value | (input[(*index)++] & 0x3f);
    }
    if ((first & 0xf8) == 0xf0 && *index + 2 < length) {
        uint32_t value = ((uint32_t)(first & 0x07) << 18) |
            ((uint32_t)(input[(*index)++] & 0x3f) << 12) |
            ((uint32_t)(input[(*index)++] & 0x3f) << 6);
        return value | (input[(*index)++] & 0x3f);
    }
    return 0xffffffffu;
}

int32_t YJ_Schema_IdnaValidate(const uint8_t *input, int64_t length, int32_t ascii_only) {
    if (input == NULL || length <= 0) {
        return 0;
    }
    if (ascii_only) {
        for (int64_t index = 0; index < length; index++) {
            if (input[index] >= 0x80) {
                return 0;
            }
            if (!((input[index] >= 'A' && input[index] <= 'Z') ||
                (input[index] >= 'a' && input[index] <= 'z') ||
                (input[index] >= '0' && input[index] <= '9') || input[index] == '-' || input[index] == '.')) {
                return 0;
            }
        }
    }
    for (int64_t index = 0; index < length; index++) {
        if (input[index] <= 0x20 || input[index] == 0x7f) {
            return 0;
        }
    }
    int domain_has_rtl = 0;
    int bad_digit_start = 0;
    int label_has_rtl = 0;
    int label_has_ascii_digit = 0;
    int label_has_arabic_digit = 0;
    int label_start = 1;
    for (int64_t index = 0; index < length;) {
        uint32_t codepoint = yj_schema_next_utf8(input, length, &index);
        if (codepoint == '.') {
            if (label_has_rtl && label_has_ascii_digit && label_has_arabic_digit) return 0;
            label_has_rtl = label_has_ascii_digit = label_has_arabic_digit = 0;
            label_start = 1;
            continue;
        }
        int rtl = (codepoint >= 0x0590 && codepoint <= 0x08ff);
        if (rtl) {
            domain_has_rtl = 1;
            label_has_rtl = 1;
        }
        if (codepoint >= '0' && codepoint <= '9') {
            label_has_ascii_digit = 1;
            if (label_start) bad_digit_start = 1;
        }
        if (codepoint >= 0x0660 && codepoint <= 0x0669) label_has_arabic_digit = 1;
        label_start = 0;
    }
    if (label_has_rtl && label_has_ascii_digit && label_has_arabic_digit) return 0;
    if (domain_has_rtl && bad_digit_start) return 0;
    char *copy = (char *)malloc((size_t)length + 1);
    if (copy == NULL) {
        return 0;
    }
    memcpy(copy, input, (size_t)length);
    copy[length] = '\0';
    uint8_t *ascii = NULL;
    int status = idn2_lookup_u8((const uint8_t *)copy, &ascii,
        IDN2_NFC_INPUT | IDN2_ALABEL_ROUNDTRIP | IDN2_NONTRANSITIONAL |
        IDN2_USE_STD3_ASCII_RULES);
    free(copy);
    int valid = ascii != NULL && strlen((const char *)ascii) <= 253;
    if (valid) {
        char *cursor = (char *)ascii;
        while (valid) {
            char *dot = strchr(cursor, '.');
            size_t label_length = dot == NULL ? strlen(cursor) : (size_t)(dot - cursor);
            if (label_length == 0 || label_length > 63 || cursor[0] == '-' || cursor[label_length - 1] == '-') {
                valid = 0;
                break;
            }
            for (size_t index = 0; index < label_length; index++) {
                unsigned char byte = (unsigned char)cursor[index];
                if (!((byte >= 'A' && byte <= 'Z') || (byte >= 'a' && byte <= 'z') ||
                    (byte >= '0' && byte <= '9') || byte == '-')) {
                    valid = 0;
                    break;
                }
            }
            if (!valid) {
                break;
            }
            if (label_length >= 4 && (cursor[0] == 'x' || cursor[0] == 'X') &&
                (cursor[1] == 'n' || cursor[1] == 'N') && cursor[2] == '-' && cursor[3] == '-') {
                char saved = cursor[label_length];
                cursor[label_length] = '\0';
                uint8_t *registered = NULL;
                int registered_status = idn2_register_u8(NULL, (const uint8_t *)cursor, &registered,
                    IDN2_NFC_INPUT | IDN2_ALABEL_ROUNDTRIP | IDN2_NONTRANSITIONAL |
                    IDN2_USE_STD3_ASCII_RULES);
                cursor[label_length] = saved;
                if (registered != NULL) {
                    idn2_free(registered);
                }
                if (registered_status != IDN2_OK) {
                    valid = 0;
                    break;
                }
            }
            if (dot == NULL) {
                break;
            }
            cursor = dot + 1;
        }
    }
    if (ascii != NULL) {
        idn2_free(ascii);
    }
    return status == IDN2_OK && valid ? 1 : 0;
}
