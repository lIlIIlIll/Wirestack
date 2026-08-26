#include "yjson_scanner.h"

#include <stddef.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

#if defined(__x86_64__) || defined(__i386__)
#include <cpuid.h>
#include <immintrin.h>
#endif

uint32_t YJ_JSON_ProbeV1(void)
{
    /* Every required primitive is compiled into this translation unit. The
     * versioned probe is the single initialization handshake; changing the
     * bundle ABI requires a new probe symbol and value. */
    return YJ_JSON_ACCEL_PROBE_V1;
}

double YJ_JSON_ParseDouble(const uint8_t* input, int64_t len,
    int64_t start, int64_t tokenLength)
{
    enum { MAX_TOKEN_BYTES = 256 };
    if (input == NULL || len < 0 || start < 0 || tokenLength <= 0 ||
        tokenLength > MAX_TOKEN_BYTES || start > len - tokenLength) {
        return NAN;
    }

    char token[MAX_TOKEN_BYTES + 1];
    memcpy(token, input + start, (size_t)tokenLength);
    token[tokenLength] = '\0';

    char* end = NULL;
    double value = strtod(token, &end);
    if (end != token + tokenLength) {
        return NAN;
    }
    return value;
}

static int yj_json_writer_needs_html_escape(uint8_t value) {
    return value == '<' || value == '>' || value == '&' || value == '=' || value == '\'';
}

int32_t YJ_JSON_EscapeString(const uint8_t* input, int64_t len, uint8_t htmlSafe,
    uint8_t* output, int64_t outputCap, int64_t* outWritten) {
    static const uint8_t hex[] = "0123456789abcdef";
    int64_t written = 0;
    if (input == NULL || output == NULL || outWritten == NULL || len < 0 || outputCap < 2) {
        return YJ_JSON_SCAN_ERROR;
    }
#define YJ_WRITE_BYTE(byteValue) do { \
        if (written >= outputCap) return YJ_JSON_SCAN_CAPACITY; \
        output[written++] = (uint8_t)(byteValue); \
    } while (0)
    YJ_WRITE_BYTE('"');
    for (int64_t index = 0; index < len; ++index) {
        uint8_t value = input[index];
        if (value >= 0x20 && value != '"' && value != '\\' &&
            (!htmlSafe || !yj_json_writer_needs_html_escape(value))) {
            YJ_WRITE_BYTE(value);
            continue;
        }
        YJ_WRITE_BYTE('\\');
        switch (value) {
            case '"': YJ_WRITE_BYTE('"'); break;
            case '\\': YJ_WRITE_BYTE('\\'); break;
            case '\b': YJ_WRITE_BYTE('b'); break;
            case '\f': YJ_WRITE_BYTE('f'); break;
            case '\n': YJ_WRITE_BYTE('n'); break;
            case '\r': YJ_WRITE_BYTE('r'); break;
            case '\t': YJ_WRITE_BYTE('t'); break;
            default:
                YJ_WRITE_BYTE('u'); YJ_WRITE_BYTE('0'); YJ_WRITE_BYTE('0');
                YJ_WRITE_BYTE(hex[value >> 4]); YJ_WRITE_BYTE(hex[value & 0x0f]);
                break;
        }
    }
    YJ_WRITE_BYTE('"');
#undef YJ_WRITE_BYTE
    *outWritten = written;
    return YJ_JSON_SCAN_OK;
}

static int32_t yj_json_write_int64(uint8_t* output, int64_t outputCap,
    int64_t* written, int64_t value)
{
    uint8_t digits[20];
    int32_t count = 0;
    uint64_t magnitude;
    if (value < 0) {
        if (*written >= outputCap) return YJ_JSON_SCAN_CAPACITY;
        output[(*written)++] = '-';
        magnitude = (uint64_t)(-(value + 1)) + 1u;
    } else {
        magnitude = (uint64_t)value;
    }
    do {
        digits[count++] = (uint8_t)('0' + (magnitude % 10u));
        magnitude /= 10u;
    } while (magnitude != 0u);
    if (*written > outputCap - count) return YJ_JSON_SCAN_CAPACITY;
    while (count > 0) output[(*written)++] = digits[--count];
    return YJ_JSON_SCAN_OK;
}

int32_t YJ_JSON_FormatInt64Array(const int64_t* values, int64_t count,
    uint8_t* output, int64_t outputCap, int64_t outputOffset,
    int64_t* outWritten)
{
    if (values == NULL || output == NULL || outWritten == NULL || count < 0 ||
        outputOffset < 0 || outputOffset > outputCap ||
        outputCap - outputOffset < 2) return YJ_JSON_SCAN_ERROR;
    output += outputOffset;
    outputCap -= outputOffset;
    int64_t written = 0;
    output[written++] = '[';
    for (int64_t index = 0; index < count; ++index) {
        if (index > 0) {
            if (written >= outputCap) return YJ_JSON_SCAN_CAPACITY;
            output[written++] = ',';
        }
        int32_t status = yj_json_write_int64(output, outputCap, &written, values[index]);
        if (status != YJ_JSON_SCAN_OK) return status;
    }
    if (written >= outputCap) return YJ_JSON_SCAN_CAPACITY;
    output[written++] = ']';
    *outWritten = written;
    return YJ_JSON_SCAN_OK;
}

enum {
    TOKEN_OBJECT_START = 1,
    TOKEN_OBJECT_END = 2,
    TOKEN_ARRAY_START = 3,
    TOKEN_ARRAY_END = 4,
    TOKEN_COLON = 5,
    TOKEN_COMMA = 6,
    TOKEN_STRING = 7
};

typedef struct {
    const uint8_t* data;
    int64_t len;
    int64_t pos;
    uint32_t flags;
    int64_t error;
    int32_t fallback;
    int32_t depth;
} YjParser;

static int32_t is_space(uint8_t value)
{
    return value == ' ' || value == '\n' || value == '\r' || value == '\t';
}

static int32_t is_digit(uint8_t value)
{
    return value >= '0' && value <= '9';
}

static int32_t hex_value(uint8_t value)
{
    if (value >= '0' && value <= '9') {
        return (int32_t)(value - '0');
    }
    if (value >= 'a' && value <= 'f') {
        return (int32_t)(value - 'a') + 10;
    }
    if (value >= 'A' && value <= 'F') {
        return (int32_t)(value - 'A') + 10;
    }
    return -1;
}

static int32_t is_high_surrogate(int32_t value)
{
    return value >= 0xD800 && value <= 0xDBFF;
}

static int32_t is_low_surrogate(int32_t value)
{
    return value >= 0xDC00 && value <= 0xDFFF;
}

static void set_error(YjParser* parser, int64_t offset)
{
    if (parser->error < 0) {
        parser->error = offset;
    }
}

static int32_t fail_at(YjParser* parser, int64_t offset)
{
    set_error(parser, offset);
    return YJ_JSON_SCAN_ERROR;
}

static int32_t need_fallback(YjParser* parser)
{
    parser->fallback = 1;
    return YJ_JSON_SCAN_FALLBACK;
}

static void skip_ws(YjParser* parser)
{
    while (parser->pos < parser->len && is_space(parser->data[parser->pos])) {
        parser->pos++;
    }
}

static int32_t parse_hex4(YjParser* parser, int64_t start, int32_t* out)
{
    int32_t value = 0;
    if (parser->pos + 4 > parser->len) {
        return fail_at(parser, start);
    }
    for (int32_t i = 0; i < 4; i++) {
        int32_t digit = hex_value(parser->data[parser->pos]);
        if (digit < 0) {
            return fail_at(parser, parser->pos);
        }
        value = value * 16 + digit;
        parser->pos++;
    }
    *out = value;
    return YJ_JSON_SCAN_OK;
}

static int32_t skip_unicode_escape(YjParser* parser, int64_t start)
{
    int32_t value = 0;
    int32_t status = parse_hex4(parser, start, &value);
    if (status != YJ_JSON_SCAN_OK) {
        return status;
    }
    if (is_high_surrogate(value)) {
        if (parser->pos + 2 > parser->len ||
            parser->data[parser->pos] != '\\' ||
            parser->data[parser->pos + 1] != 'u') {
            return fail_at(parser, start);
        }
        parser->pos += 2;
        int32_t low = 0;
        status = parse_hex4(parser, parser->pos, &low);
        if (status != YJ_JSON_SCAN_OK) {
            return status;
        }
        if (!is_low_surrogate(low)) {
            return fail_at(parser, start);
        }
        return YJ_JSON_SCAN_OK;
    }
    if (is_low_surrogate(value)) {
        return fail_at(parser, start);
    }
    return YJ_JSON_SCAN_OK;
}

static int32_t append_utf8(uint8_t* output, int64_t outputCap, int64_t* outPos, int32_t value)
{
    if (value <= 0x7F) {
        if (*outPos + 1 > outputCap) {
            return YJ_JSON_SCAN_CAPACITY;
        }
        output[(*outPos)++] = (uint8_t)value;
        return YJ_JSON_SCAN_OK;
    }
    if (value <= 0x7FF) {
        if (*outPos + 2 > outputCap) {
            return YJ_JSON_SCAN_CAPACITY;
        }
        output[(*outPos)++] = (uint8_t)(0xC0 | (value >> 6));
        output[(*outPos)++] = (uint8_t)(0x80 | (value & 0x3F));
        return YJ_JSON_SCAN_OK;
    }
    if (value <= 0xFFFF) {
        if (*outPos + 3 > outputCap) {
            return YJ_JSON_SCAN_CAPACITY;
        }
        output[(*outPos)++] = (uint8_t)(0xE0 | (value >> 12));
        output[(*outPos)++] = (uint8_t)(0x80 | ((value >> 6) & 0x3F));
        output[(*outPos)++] = (uint8_t)(0x80 | (value & 0x3F));
        return YJ_JSON_SCAN_OK;
    }
    if (*outPos + 4 > outputCap) {
        return YJ_JSON_SCAN_CAPACITY;
    }
    output[(*outPos)++] = (uint8_t)(0xF0 | (value >> 18));
    output[(*outPos)++] = (uint8_t)(0x80 | ((value >> 12) & 0x3F));
    output[(*outPos)++] = (uint8_t)(0x80 | ((value >> 6) & 0x3F));
    output[(*outPos)++] = (uint8_t)(0x80 | (value & 0x3F));
    return YJ_JSON_SCAN_OK;
}

static int32_t decode_unicode_escape(YjParser* parser, int64_t start, uint8_t* output, int64_t outputCap, int64_t* outPos)
{
    int32_t value = 0;
    int32_t status = parse_hex4(parser, start, &value);
    if (status != YJ_JSON_SCAN_OK) {
        return status;
    }
    if (is_high_surrogate(value)) {
        if (parser->pos + 2 > parser->len ||
            parser->data[parser->pos] != '\\' ||
            parser->data[parser->pos + 1] != 'u') {
            return fail_at(parser, start);
        }
        parser->pos += 2;
        int32_t low = 0;
        status = parse_hex4(parser, parser->pos, &low);
        if (status != YJ_JSON_SCAN_OK) {
            return status;
        }
        if (!is_low_surrogate(low)) {
            return fail_at(parser, start);
        }
        value = 0x10000 + (((value - 0xD800) << 10) | (low - 0xDC00));
    } else if (is_low_surrogate(value)) {
        return fail_at(parser, start);
    }
    return append_utf8(output, outputCap, outPos, value);
}

#if defined(__x86_64__) || defined(__i386__)
static int32_t cpu_has_avx2(void)
{
    static int32_t cached = -1;
    if (cached < 0) {
        __builtin_cpu_init();
        cached = __builtin_cpu_supports("avx2") != 0 ? 1 : 0;
    }
    return cached;
}

static int32_t numeric_avx2_enabled(void)
{
    static int32_t cached = -1;
    if (cached < 0) {
        const char* forced = getenv("YJSON_NUMERIC_FORCE_SCALAR");
        cached = cpu_has_avx2() && !(forced != NULL && forced[0] == '1') ? 1 : 0;
    }
    return cached;
}

static void append_small_integer_token(
    const uint8_t* data, int64_t start, int64_t end,
    uint64_t* tokens, int64_t* count)
{
    uint64_t magnitude = 0;
    int64_t digits = end - start;
    if (digits <= 18) {
        for (int64_t at = start; at < end; at++) {
            magnitude = magnitude * 10u + (uint64_t)(data[at] - '0');
        }
    }
    int64_t base = (*count) * 4;
    tokens[base] = (uint64_t)start;
    tokens[base + 1] = (uint64_t)end;
    tokens[base + 2] = magnitude;
    tokens[base + 3] = digits <= 18 ? 4u : 0u;
    (*count)++;
}

// Emits a run of positive integer tokens. Any minus, fraction, exponent,
// whitespace, or non-number value stops before that token and lets the scalar
// grammar validator continue from the exact same byte.
__attribute__((target("avx2")))
static int32_t scan_positive_integers_avx2(
    YjParser* parser, uint64_t* tokens, int64_t tokenCap,
    int64_t* count, int64_t* outDone)
{
    const __m256i zero = _mm256_set1_epi8('0');
    const __m256i nine = _mm256_set1_epi8('9');
    const __m256i comma = _mm256_set1_epi8(',');
    const __m256i close = _mm256_set1_epi8(']');
    int64_t token_start = parser->pos;
    int64_t scan = parser->pos;
    int32_t emitted = 0;
    while (scan + 32 <= parser->len && *count < tokenCap) {
        __m256i value = _mm256_loadu_si256((const __m256i*)(const void*)(parser->data + scan));
        __m256i below_zero = _mm256_cmpgt_epi8(zero, value);
        __m256i above_nine = _mm256_cmpgt_epi8(value, nine);
        uint32_t comma_mask = (uint32_t)_mm256_movemask_epi8(_mm256_cmpeq_epi8(value, comma));
        uint32_t close_mask = (uint32_t)_mm256_movemask_epi8(_mm256_cmpeq_epi8(value, close));
        uint32_t nondigit = (uint32_t)_mm256_movemask_epi8(_mm256_or_si256(below_zero, above_nine));
        uint32_t delimiters = comma_mask | close_mask;
        uint32_t invalid = nondigit & ~delimiters;
        uint32_t interesting = delimiters | invalid;
        while (interesting != 0 && *count < tokenCap) {
            uint32_t bit = (uint32_t)__builtin_ctz(interesting);
            uint32_t mask = 1u << bit;
            int64_t at = scan + (int64_t)bit;
            if ((invalid & mask) != 0) {
                parser->pos = token_start;
                return emitted;
            }
            if (at == token_start ||
                (at - token_start > 1 && parser->data[token_start] == '0')) {
                parser->pos = token_start;
                return emitted;
            }
            append_small_integer_token(parser->data, token_start, at, tokens, count);
            emitted = 1;
            if ((close_mask & mask) != 0) {
                parser->pos = at + 1;
                *outDone = 1;
                return emitted;
            }
            token_start = at + 1;
            interesting &= ~((mask - 1u) | mask);
        }
        if (*count >= tokenCap) {
            parser->pos = token_start;
            return emitted;
        }
        scan += 32;
    }
    parser->pos = token_start;
    return emitted;
}

__attribute__((target("avx2")))
static int64_t find_numeric_tape_interesting_avx2(
    const uint8_t* data, int64_t pos, int64_t len)
{
    const __m256i zero = _mm256_set1_epi8('0');
    const __m256i nine = _mm256_set1_epi8('9');
    const __m256i quote = _mm256_set1_epi8('"');
    const __m256i minus = _mm256_set1_epi8('-');
    while (pos + 32 <= len) {
        __m256i value = _mm256_loadu_si256((const __m256i*)(const void*)(data + pos));
        __m256i below_zero = _mm256_cmpgt_epi8(zero, value);
        __m256i above_nine = _mm256_cmpgt_epi8(value, nine);
        __m256i digit = _mm256_xor_si256(_mm256_or_si256(below_zero, above_nine), _mm256_set1_epi8((char)0xFF));
        __m256i interesting = _mm256_or_si256(digit,
            _mm256_or_si256(_mm256_cmpeq_epi8(value, quote), _mm256_cmpeq_epi8(value, minus)));
        uint32_t mask = (uint32_t)_mm256_movemask_epi8(interesting);
        if (mask != 0) return pos + (int64_t)__builtin_ctz(mask);
        pos += 32;
    }
    return pos;
}

__attribute__((target("avx2")))
static int64_t find_string_special_avx2(
    const uint8_t* data,
    int64_t pos,
    int64_t len,
    int32_t stop_high)
{
    const __m256i quote = _mm256_set1_epi8('"');
    const __m256i slash = _mm256_set1_epi8('\\');
    const __m256i high_bits = _mm256_set1_epi8((char)0xE0);
    const __m256i zero = _mm256_setzero_si256();
    while (pos + 32 <= len) {
        __m256i value = _mm256_loadu_si256((const __m256i*)(const void*)(data + pos));
        __m256i quote_mask = _mm256_cmpeq_epi8(value, quote);
        __m256i slash_mask = _mm256_cmpeq_epi8(value, slash);
        __m256i control_mask = _mm256_cmpeq_epi8(_mm256_and_si256(value, high_bits), zero);
        uint32_t mask = (uint32_t)_mm256_movemask_epi8(
            _mm256_or_si256(_mm256_or_si256(quote_mask, slash_mask), control_mask));
        if (stop_high) {
            mask |= (uint32_t)_mm256_movemask_epi8(value);
        }
        if (mask != 0) {
            return pos + (int64_t)__builtin_ctz(mask);
        }
        pos += 32;
    }
    return pos;
}
#else
static int32_t cpu_has_avx2(void)
{
    return 0;
}

static int64_t find_string_special_avx2(
    const uint8_t* data,
    int64_t pos,
    int64_t len,
    int32_t stop_high)
{
    (void)data;
    (void)len;
    (void)stop_high;
    return pos;
}

static int32_t numeric_avx2_enabled(void) { return 0; }
static int32_t scan_positive_integers_avx2(
    YjParser* parser, uint64_t* tokens, int64_t tokenCap,
    int64_t* count, int64_t* outDone)
{
    (void)parser;
    (void)tokens;
    (void)tokenCap;
    (void)count;
    (void)outDone;
    return 0;
}
static int64_t find_numeric_tape_interesting_avx2(
    const uint8_t* data, int64_t pos, int64_t len)
{
    (void)data; (void)len; return pos;
}
#endif

uint32_t YJ_JSON_SimdCaps(void)
{
    uint32_t caps = 1u;
    if (cpu_has_avx2()) {
        caps |= 2u;
    }
    return caps;
}

static uint64_t name_hash_update(uint64_t hash, uint8_t byte)
{
    return (((hash << 5) - hash) + (uint64_t)byte) & 0xFFFFFFFFu;
}

static int32_t skip_string(
    YjParser* parser,
    int32_t plain_name,
    int64_t* out_name_start,
    int64_t* out_name_len,
    uint64_t* out_hash)
{
    if (parser->pos >= parser->len || parser->data[parser->pos] != '"') {
        return fail_at(parser, parser->pos);
    }
    parser->pos++;
    int64_t start = parser->pos;
    uint64_t hash = 0;
    int32_t stop_high = plain_name || ((parser->flags & YJ_JSON_SCAN_VALIDATE_STRINGS) != 0);
    int32_t use_avx2 = !plain_name && cpu_has_avx2();
    while (parser->pos < parser->len) {
        if (use_avx2) {
            int64_t next = find_string_special_avx2(parser->data, parser->pos, parser->len, stop_high);
            parser->pos = next;
            if (parser->pos >= parser->len) {
                break;
            }
        }
        uint8_t current = parser->data[parser->pos++];
        if (current == '"') {
            if (out_name_start != NULL) {
                *out_name_start = start;
            }
            if (out_name_len != NULL) {
                *out_name_len = parser->pos - start - 1;
            }
            if (out_hash != NULL) {
                *out_hash = hash;
            }
            return YJ_JSON_SCAN_OK;
        }
        if (current == '\\') {
            if (plain_name) {
                return need_fallback(parser);
            }
            if (parser->pos >= parser->len) {
                return fail_at(parser, parser->pos);
            }
            uint8_t escaped = parser->data[parser->pos++];
            switch (escaped) {
                case '"':
                case '\\':
                case '/':
                case 'b':
                case 'f':
                case 'n':
                case 'r':
                case 't':
                    break;
                case 'u': {
                    int32_t status = skip_unicode_escape(parser, parser->pos);
                    if (status != YJ_JSON_SCAN_OK) {
                        return status;
                    }
                    break;
                }
                default:
                    return fail_at(parser, parser->pos - 2);
            }
            continue;
        }
        if (current < 0x20) {
            return fail_at(parser, parser->pos - 1);
        }
        if (current >= 0x80 && stop_high) {
            return need_fallback(parser);
        }
        if (plain_name) {
            hash = name_hash_update(hash, current);
        }
    }
    return fail_at(parser, parser->len);
}

static int32_t expect_literal(YjParser* parser, const char* literal)
{
    int64_t start = parser->pos;
    for (int64_t i = 0; literal[i] != 0; i++) {
        if (parser->pos >= parser->len || parser->data[parser->pos] != (uint8_t)literal[i]) {
            return fail_at(parser, start);
        }
        parser->pos++;
    }
    return YJ_JSON_SCAN_OK;
}

static int32_t skip_number(YjParser* parser)
{
    if (parser->pos < parser->len && parser->data[parser->pos] == '-') {
        parser->pos++;
    }
    if (parser->pos >= parser->len || !is_digit(parser->data[parser->pos])) {
        return fail_at(parser, parser->pos);
    }
    if (parser->data[parser->pos] == '0') {
        parser->pos++;
        if (parser->pos < parser->len && is_digit(parser->data[parser->pos])) {
            return fail_at(parser, parser->pos);
        }
    } else {
        while (parser->pos < parser->len && is_digit(parser->data[parser->pos])) {
            parser->pos++;
        }
    }
    if (parser->pos < parser->len && parser->data[parser->pos] == '.') {
        parser->pos++;
        if (parser->pos >= parser->len || !is_digit(parser->data[parser->pos])) {
            return fail_at(parser, parser->pos);
        }
        while (parser->pos < parser->len && is_digit(parser->data[parser->pos])) {
            parser->pos++;
        }
    }
    if (parser->pos < parser->len &&
        (parser->data[parser->pos] == 'e' || parser->data[parser->pos] == 'E')) {
        parser->pos++;
        if (parser->pos < parser->len &&
            (parser->data[parser->pos] == '+' || parser->data[parser->pos] == '-')) {
            parser->pos++;
        }
        if (parser->pos >= parser->len || !is_digit(parser->data[parser->pos])) {
            return fail_at(parser, parser->pos);
        }
        while (parser->pos < parser->len && is_digit(parser->data[parser->pos])) {
            parser->pos++;
        }
    }
    return YJ_JSON_SCAN_OK;
}

static int32_t skip_value(YjParser* parser);

static int32_t skip_array(YjParser* parser)
{
    if (parser->depth++ > 2048) {
        parser->depth--;
        return need_fallback(parser);
    }
    parser->pos++;
    skip_ws(parser);
    if (parser->pos < parser->len && parser->data[parser->pos] == ']') {
        parser->pos++;
        parser->depth--;
        return YJ_JSON_SCAN_OK;
    }
    while (parser->pos < parser->len) {
        int32_t status = skip_value(parser);
        if (status != YJ_JSON_SCAN_OK) {
            parser->depth--;
            return status;
        }
        skip_ws(parser);
        if (parser->pos < parser->len && parser->data[parser->pos] == ']') {
            parser->pos++;
            parser->depth--;
            return YJ_JSON_SCAN_OK;
        }
        if (parser->pos >= parser->len || parser->data[parser->pos] != ',') {
            parser->depth--;
            return fail_at(parser, parser->pos);
        }
        parser->pos++;
        skip_ws(parser);
    }
    parser->depth--;
    return fail_at(parser, parser->len);
}

static int32_t skip_object(YjParser* parser)
{
    if (parser->depth++ > 2048) {
        parser->depth--;
        return need_fallback(parser);
    }
    parser->pos++;
    skip_ws(parser);
    if (parser->pos < parser->len && parser->data[parser->pos] == '}') {
        parser->pos++;
        parser->depth--;
        return YJ_JSON_SCAN_OK;
    }
    while (parser->pos < parser->len) {
        int32_t status = skip_string(parser, 0, NULL, NULL, NULL);
        if (status != YJ_JSON_SCAN_OK) {
            parser->depth--;
            return status;
        }
        skip_ws(parser);
        if (parser->pos >= parser->len || parser->data[parser->pos] != ':') {
            parser->depth--;
            return fail_at(parser, parser->pos);
        }
        parser->pos++;
        status = skip_value(parser);
        if (status != YJ_JSON_SCAN_OK) {
            parser->depth--;
            return status;
        }
        skip_ws(parser);
        if (parser->pos < parser->len && parser->data[parser->pos] == '}') {
            parser->pos++;
            parser->depth--;
            return YJ_JSON_SCAN_OK;
        }
        if (parser->pos >= parser->len || parser->data[parser->pos] != ',') {
            parser->depth--;
            return fail_at(parser, parser->pos);
        }
        parser->pos++;
        skip_ws(parser);
    }
    parser->depth--;
    return fail_at(parser, parser->len);
}

static int32_t skip_value(YjParser* parser)
{
    skip_ws(parser);
    if (parser->pos >= parser->len) {
        return fail_at(parser, parser->pos);
    }
    uint8_t current = parser->data[parser->pos];
    switch (current) {
        case 'n':
            return expect_literal(parser, "null");
        case 't':
            return expect_literal(parser, "true");
        case 'f':
            return expect_literal(parser, "false");
        case '"':
            return skip_string(parser, 0, NULL, NULL, NULL);
        case '[':
            return skip_array(parser);
        case '{':
            return skip_object(parser);
        default:
            if (current == '-' || is_digit(current)) {
                return skip_number(parser);
            }
            return fail_at(parser, parser->pos);
    }
}

static YjParser make_parser(const uint8_t* input, int64_t len, int64_t start, uint32_t flags)
{
    YjParser parser;
    parser.data = input;
    parser.len = len;
    parser.pos = start;
    parser.flags = flags;
    parser.error = -1;
    parser.fallback = 0;
    parser.depth = 0;
    return parser;
}

static int32_t finish_status(YjParser* parser, int32_t status, int64_t* outError)
{
    if (status == YJ_JSON_SCAN_ERROR && outError != NULL) {
        *outError = parser->error >= 0 ? parser->error : parser->pos;
    }
    return status;
}

int32_t YJ_JSON_ParseInt64Array(
    const uint8_t* input, int64_t len, int64_t start,
    int64_t* values, int64_t valueCap,
    int64_t* outEnd, int64_t* outCount, int64_t* outError)
{
    if (input == NULL || values == NULL || outEnd == NULL || outCount == NULL ||
        outError == NULL || start < 0 || start > len || valueCap < 0) {
        if (outError != NULL) *outError = start;
        return YJ_JSON_SCAN_ERROR;
    }
    YjParser parser = make_parser(input, len, start, 0u);
    skip_ws(&parser);
    if (parser.pos >= parser.len || parser.data[parser.pos] != '[') {
        *outError = parser.pos;
        return YJ_JSON_SCAN_FALLBACK;
    }
    parser.pos++;
    skip_ws(&parser);
    int64_t count = 0;
    if (parser.pos < parser.len && parser.data[parser.pos] == ']') {
        parser.pos++;
        *outEnd = parser.pos; *outCount = 0; *outError = -1;
        return YJ_JSON_SCAN_OK;
    }
    while (parser.pos < parser.len) {
        if (count >= valueCap) {
            *outError = count + 1;
            return YJ_JSON_SCAN_CAPACITY;
        }
        int32_t negative = parser.data[parser.pos] == '-';
        if (negative) parser.pos++;
        if (parser.pos >= parser.len || !is_digit(parser.data[parser.pos])) {
            *outError = parser.pos;
            return YJ_JSON_SCAN_FALLBACK;
        }
        uint64_t magnitude = 0;
        const uint64_t limit = negative ? UINT64_C(9223372036854775808) : UINT64_C(9223372036854775807);
        if (parser.data[parser.pos] == '0') {
            parser.pos++;
            if (parser.pos < parser.len && is_digit(parser.data[parser.pos])) {
                *outError = parser.pos;
                return YJ_JSON_SCAN_FALLBACK;
            }
        } else {
            while (parser.pos < parser.len && is_digit(parser.data[parser.pos])) {
                uint64_t digit = (uint64_t)(parser.data[parser.pos] - '0');
                if (magnitude > (limit - digit) / 10u) {
                    *outError = parser.pos;
                    return YJ_JSON_SCAN_FALLBACK;
                }
                magnitude = magnitude * 10u + digit;
                parser.pos++;
            }
        }
        if (negative) {
            values[count] = magnitude == UINT64_C(9223372036854775808)
                ? INT64_MIN : -(int64_t)magnitude;
        } else {
            values[count] = (int64_t)magnitude;
        }
        count++;
        skip_ws(&parser);
        if (parser.pos < parser.len && parser.data[parser.pos] == ']') {
            parser.pos++;
            *outEnd = parser.pos; *outCount = count; *outError = -1;
            return YJ_JSON_SCAN_OK;
        }
        if (parser.pos >= parser.len || parser.data[parser.pos] != ',') {
            *outError = parser.pos;
            return YJ_JSON_SCAN_FALLBACK;
        }
        parser.pos++;
        skip_ws(&parser);
    }
    *outError = parser.pos;
    return YJ_JSON_SCAN_FALLBACK;
}

int32_t YJ_JSON_SkipValue(
    const uint8_t* input, int64_t len, int64_t start, uint32_t flags,
    int64_t* outEnd, int64_t* outError)
{
    if (input == NULL || outEnd == NULL || outError == NULL || start < 0 || start > len) {
        if (outError != NULL) {
            *outError = start;
        }
        return YJ_JSON_SCAN_ERROR;
    }
    YjParser parser = make_parser(input, len, start, flags);
    int32_t status = skip_value(&parser);
    if (status == YJ_JSON_SCAN_OK) {
        *outEnd = parser.pos;
        *outError = -1;
        return YJ_JSON_SCAN_OK;
    }
    return finish_status(&parser, status, outError);
}

int32_t YJ_JSON_ScanString(
    const uint8_t* input, int64_t len, int64_t start, uint32_t flags,
    int64_t* outEnd, int64_t* outError)
{
    if (input == NULL || outEnd == NULL || outError == NULL || start < 0 || start > len) {
        if (outError != NULL) {
            *outError = start;
        }
        return YJ_JSON_SCAN_ERROR;
    }
    YjParser parser = make_parser(input, len, start, flags);
    int32_t status = skip_string(&parser, 0, NULL, NULL, NULL);
    if (status == YJ_JSON_SCAN_OK) {
        *outEnd = parser.pos;
        *outError = -1;
        return YJ_JSON_SCAN_OK;
    }
    return finish_status(&parser, status, outError);
}

int32_t YJ_JSON_DecodeString(
    const uint8_t* input, int64_t len, int64_t start, uint32_t flags,
    uint8_t* output, int64_t outputCap,
    int64_t* outEnd, int64_t* outWritten, int64_t* outError)
{
    if (input == NULL || output == NULL || outEnd == NULL || outWritten == NULL || outError == NULL ||
        start < 0 || start > len || outputCap < 0) {
        if (outError != NULL) {
            *outError = start;
        }
        return YJ_JSON_SCAN_ERROR;
    }
    YjParser parser = make_parser(input, len, start, flags);
    if (parser.pos >= parser.len || parser.data[parser.pos] != '"') {
        return finish_status(&parser, fail_at(&parser, parser.pos), outError);
    }
    parser.pos++;
    int64_t written = 0;
    int32_t validate_raw_utf8 = (flags & YJ_JSON_SCAN_VALIDATE_STRINGS) != 0;
    while (parser.pos < parser.len) {
        int64_t current_start = parser.pos;
        uint8_t current = parser.data[parser.pos++];
        if (current == '"') {
            *outEnd = parser.pos;
            *outWritten = written;
            *outError = -1;
            return YJ_JSON_SCAN_OK;
        }
        if (current == '\\') {
            if (parser.pos >= parser.len) {
                return finish_status(&parser, fail_at(&parser, parser.pos), outError);
            }
            uint8_t escaped = parser.data[parser.pos++];
            switch (escaped) {
                case '"':
                case '\\':
                case '/':
                    if (written + 1 > outputCap) {
                        *outError = written + 1;
                        return YJ_JSON_SCAN_CAPACITY;
                    }
                    output[written++] = escaped;
                    break;
                case 'b':
                    if (written + 1 > outputCap) {
                        *outError = written + 1;
                        return YJ_JSON_SCAN_CAPACITY;
                    }
                    output[written++] = '\b';
                    break;
                case 'f':
                    if (written + 1 > outputCap) {
                        *outError = written + 1;
                        return YJ_JSON_SCAN_CAPACITY;
                    }
                    output[written++] = '\f';
                    break;
                case 'n':
                    if (written + 1 > outputCap) {
                        *outError = written + 1;
                        return YJ_JSON_SCAN_CAPACITY;
                    }
                    output[written++] = '\n';
                    break;
                case 'r':
                    if (written + 1 > outputCap) {
                        *outError = written + 1;
                        return YJ_JSON_SCAN_CAPACITY;
                    }
                    output[written++] = '\r';
                    break;
                case 't':
                    if (written + 1 > outputCap) {
                        *outError = written + 1;
                        return YJ_JSON_SCAN_CAPACITY;
                    }
                    output[written++] = '\t';
                    break;
                case 'u': {
                    int32_t status = decode_unicode_escape(&parser, parser.pos, output, outputCap, &written);
                    if (status != YJ_JSON_SCAN_OK) {
                        return finish_status(&parser, status, outError);
                    }
                    break;
                }
                default:
                    return finish_status(&parser, fail_at(&parser, current_start), outError);
            }
            continue;
        }
        if (current < 0x20) {
            return finish_status(&parser, fail_at(&parser, current_start), outError);
        }
        if (current >= 0x80 && validate_raw_utf8) {
            return finish_status(&parser, need_fallback(&parser), outError);
        }
        if (written + 1 > outputCap) {
            *outError = written + 1;
            return YJ_JSON_SCAN_CAPACITY;
        }
        output[written++] = current;
    }
    return finish_status(&parser, fail_at(&parser, parser.len), outError);
}

int32_t YJ_JSON_ScanObjectFields(
    const uint8_t* input, int64_t len, int64_t start, uint32_t flags,
    uint64_t* fields, int64_t fieldCap,
    int64_t* outEnd, int64_t* outError)
{
    if (input == NULL || outEnd == NULL || outError == NULL || start < 0 || start > len || fieldCap < 0) {
        if (outError != NULL) {
            *outError = start;
        }
        return YJ_JSON_SCAN_ERROR;
    }
    YjParser parser = make_parser(input, len, start, flags);
    skip_ws(&parser);
    if (parser.pos >= parser.len || parser.data[parser.pos] != '{') {
        return finish_status(&parser, fail_at(&parser, parser.pos), outError);
    }
    parser.pos++;
    skip_ws(&parser);
    int64_t count = 0;
    if (parser.pos < parser.len && parser.data[parser.pos] == '}') {
        parser.pos++;
        *outEnd = parser.pos;
        *outError = -1;
        return YJ_JSON_SCAN_OK;
    }
    while (parser.pos < parser.len) {
        int64_t name_start = 0;
        int64_t name_len = 0;
        uint64_t hash = 0;
        int32_t status = skip_string(&parser, 1, &name_start, &name_len, &hash);
        if (status != YJ_JSON_SCAN_OK) {
            return finish_status(&parser, status, outError);
        }
        skip_ws(&parser);
        if (parser.pos >= parser.len || parser.data[parser.pos] != ':') {
            return finish_status(&parser, fail_at(&parser, parser.pos), outError);
        }
        parser.pos++;
        skip_ws(&parser);
        int64_t value_start = parser.pos;
        status = skip_value(&parser);
        if (status != YJ_JSON_SCAN_OK) {
            return finish_status(&parser, status, outError);
        }
        int64_t value_end = parser.pos;
        if (count >= fieldCap) {
            *outError = count + 1;
            return YJ_JSON_SCAN_CAPACITY;
        }
        if (fields != NULL) {
            int64_t base = count * 5;
            fields[base] = (uint64_t)name_start;
            fields[base + 1] = (uint64_t)name_len;
            fields[base + 2] = hash;
            fields[base + 3] = (uint64_t)value_start;
            fields[base + 4] = (uint64_t)value_end;
        }
        count++;
        skip_ws(&parser);
        if (parser.pos < parser.len && parser.data[parser.pos] == '}') {
            parser.pos++;
            *outEnd = parser.pos;
            *outError = count;
            return YJ_JSON_SCAN_OK;
        }
        if (parser.pos >= parser.len || parser.data[parser.pos] != ',') {
            return finish_status(&parser, fail_at(&parser, parser.pos), outError);
        }
        parser.pos++;
        skip_ws(&parser);
    }
    return finish_status(&parser, fail_at(&parser, parser.len), outError);
}

int32_t YJ_JSON_ScanArrayElements(
    const uint8_t* input, int64_t len, int64_t start, uint32_t flags,
    uint64_t* elements, int64_t elementCap,
    int64_t* outEnd, int64_t* outError)
{
    if (input == NULL || outEnd == NULL || outError == NULL || start < 0 || start > len || elementCap < 0) {
        if (outError != NULL) {
            *outError = start;
        }
        return YJ_JSON_SCAN_ERROR;
    }
    YjParser parser = make_parser(input, len, start, flags);
    skip_ws(&parser);
    if (parser.pos >= parser.len || parser.data[parser.pos] != '[') {
        return finish_status(&parser, fail_at(&parser, parser.pos), outError);
    }
    parser.pos++;
    skip_ws(&parser);
    int64_t count = 0;
    if (parser.pos < parser.len && parser.data[parser.pos] == ']') {
        parser.pos++;
        *outEnd = parser.pos;
        *outError = -1;
        return YJ_JSON_SCAN_OK;
    }
    while (parser.pos < parser.len) {
        int64_t value_start = parser.pos;
        int32_t status = skip_value(&parser);
        if (status != YJ_JSON_SCAN_OK) {
            return finish_status(&parser, status, outError);
        }
        int64_t value_end = parser.pos;
        if (count >= elementCap) {
            *outError = count + 1;
            return YJ_JSON_SCAN_CAPACITY;
        }
        if (elements != NULL) {
            int64_t base = count * 2;
            elements[base] = (uint64_t)value_start;
            elements[base + 1] = (uint64_t)value_end;
        }
        count++;
        skip_ws(&parser);
        if (parser.pos < parser.len && parser.data[parser.pos] == ']') {
            parser.pos++;
            *outEnd = parser.pos;
            *outError = count;
            return YJ_JSON_SCAN_OK;
        }
        if (parser.pos >= parser.len || parser.data[parser.pos] != ',') {
            return finish_status(&parser, fail_at(&parser, parser.pos), outError);
        }
        parser.pos++;
        skip_ws(&parser);
    }
    return finish_status(&parser, fail_at(&parser, parser.len), outError);
}

int32_t YJ_JSON_ScanNumericArrayChunk(
    const uint8_t* input, int64_t len, int64_t start, uint32_t flags,
    uint64_t* tokens, int64_t tokenCap,
    int64_t* outNext, int64_t* outCount, int64_t* outDone, int64_t* outError)
{
    if (input == NULL || tokens == NULL || outNext == NULL || outCount == NULL ||
        outDone == NULL || outError == NULL || start < 0 || start > len || tokenCap <= 0) {
        if (outError != NULL) *outError = start;
        return YJ_JSON_SCAN_ERROR;
    }
    YjParser parser = make_parser(input, len, start, flags);
    skip_ws(&parser);
    int64_t count = 0;
    *outDone = 0;
    while (parser.pos < parser.len && count < tokenCap) {
        if (parser.data[parser.pos] == ']') {
            parser.pos++;
            *outNext = parser.pos; *outCount = count; *outDone = 1; *outError = -1;
            return YJ_JSON_SCAN_OK;
        }
        if (parser.data[parser.pos] != '-' && !is_digit(parser.data[parser.pos])) {
            *outNext = parser.pos; *outCount = count; *outError = -1;
            return YJ_JSON_SCAN_FALLBACK;
        }
        if (is_digit(parser.data[parser.pos]) && numeric_avx2_enabled()) {
            int32_t emitted = scan_positive_integers_avx2(
                &parser, tokens, tokenCap, &count, outDone);
            if (*outDone) {
                *outNext = parser.pos; *outCount = count; *outError = -1;
                return YJ_JSON_SCAN_OK;
            }
            if (emitted && count >= tokenCap) {
                *outNext = parser.pos; *outCount = count; *outError = -1;
                return YJ_JSON_SCAN_OK;
            }
            if (emitted) {
                skip_ws(&parser);
            }
        }
        int64_t token_start = parser.pos;
        uint64_t magnitude = 0;
        uint64_t token_flags = 0;
        int64_t digits = 0;
        int64_t scale = 0;
        if (parser.data[parser.pos] == '-') { token_flags |= 1u; parser.pos++; }
        if (parser.pos >= parser.len || !is_digit(parser.data[parser.pos])) {
            return finish_status(&parser, fail_at(&parser, parser.pos), outError);
        }
        if (parser.data[parser.pos] == '0') {
            magnitude = 0; digits = 1; parser.pos++;
            if (parser.pos < parser.len && is_digit(parser.data[parser.pos])) {
                return finish_status(&parser, fail_at(&parser, parser.pos), outError);
            }
        } else {
            while (parser.pos < parser.len && is_digit(parser.data[parser.pos])) {
                if (digits < 18) magnitude = magnitude * 10u + (uint64_t)(parser.data[parser.pos] - '0');
                digits++; parser.pos++;
            }
        }
        if (parser.pos < parser.len && parser.data[parser.pos] == '.') {
            parser.pos++;
            if (parser.pos >= parser.len || !is_digit(parser.data[parser.pos])) {
                return finish_status(&parser, fail_at(&parser, parser.pos), outError);
            }
            while (parser.pos < parser.len && is_digit(parser.data[parser.pos])) {
                if (digits < 18) magnitude = magnitude * 10u + (uint64_t)(parser.data[parser.pos] - '0');
                digits++; scale++; parser.pos++;
            }
        }
        if (parser.pos < parser.len && (parser.data[parser.pos] == 'e' || parser.data[parser.pos] == 'E')) {
            token_flags |= 2u; parser.pos++;
            if (parser.pos < parser.len && (parser.data[parser.pos] == '+' || parser.data[parser.pos] == '-')) parser.pos++;
            if (parser.pos >= parser.len || !is_digit(parser.data[parser.pos])) {
                return finish_status(&parser, fail_at(&parser, parser.pos), outError);
            }
            while (parser.pos < parser.len && is_digit(parser.data[parser.pos])) parser.pos++;
        }
        if (digits <= 18) token_flags |= 4u;
        token_flags |= ((uint64_t)scale << 8);
        int64_t base = count * 4;
        tokens[base] = (uint64_t)token_start;
        tokens[base + 1] = (uint64_t)parser.pos;
        tokens[base + 2] = magnitude;
        tokens[base + 3] = token_flags;
        count++;
        skip_ws(&parser);
        if (parser.pos < parser.len && parser.data[parser.pos] == ']') {
            parser.pos++;
            *outNext = parser.pos; *outCount = count; *outDone = 1; *outError = -1;
            return YJ_JSON_SCAN_OK;
        }
        if (parser.pos >= parser.len || parser.data[parser.pos] != ',') {
            return finish_status(&parser, fail_at(&parser, parser.pos), outError);
        }
        parser.pos++; skip_ws(&parser);
    }
    *outNext = parser.pos; *outCount = count; *outError = -1;
    return YJ_JSON_SCAN_OK;
}

int32_t YJ_JSON_ScanNumericTape(
    const uint8_t* input, int64_t len, int64_t start, int64_t pageBytes,
    uint32_t flags, uint64_t* tokens, int64_t tokenCap,
    int64_t* outNext, int64_t* outCount, int64_t* outError)
{
    if (input == NULL || tokens == NULL || outNext == NULL || outCount == NULL ||
        outError == NULL || start < 0 || start > len || pageBytes <= 0 || tokenCap <= 0) {
        if (outError != NULL) *outError = start;
        return YJ_JSON_SCAN_ERROR;
    }
    int64_t limit = start + pageBytes;
    if (limit < start || limit > len) limit = len;
    YjParser parser = make_parser(input, limit, start, flags);
    int64_t count = 0;
    while (parser.pos < parser.len && count < tokenCap) {
        uint8_t current = parser.data[parser.pos];
        if (current == '"') {
            int64_t string_start = parser.pos;
            if (skip_string(&parser, 0, NULL, NULL, NULL) != YJ_JSON_SCAN_OK) {
                /* A page may end inside a valid string. The parser consumes the
                 * string itself; the next fill restarts at its next grammar
                 * boundary rather than retaining partial string state. */
                parser.pos = string_start;
                break;
            }
            continue;
        }
        if (current != '-' && !is_digit(current)) {
            if (numeric_avx2_enabled()) {
                int64_t next = find_numeric_tape_interesting_avx2(parser.data, parser.pos, parser.len);
                parser.pos = next > parser.pos ? next : parser.pos + 1;
            } else {
                parser.pos++;
            }
            continue;
        }
        int64_t token_start = parser.pos;
        uint64_t magnitude = 0;
        uint64_t token_flags = 0;
        int64_t digits = 0;
        int64_t scale = 0;
        if (current == '-') { token_flags |= 1u; parser.pos++; }
        if (parser.pos >= parser.len || !is_digit(parser.data[parser.pos])) {
            parser.pos = token_start + 1;
            continue;
        }
        if (parser.data[parser.pos] == '0') {
            digits = 1; parser.pos++;
        } else {
            while (parser.pos < parser.len && is_digit(parser.data[parser.pos])) {
                if (digits < 18) magnitude = magnitude * 10u + (uint64_t)(parser.data[parser.pos] - '0');
                digits++; parser.pos++;
            }
        }
        if (parser.pos < parser.len && parser.data[parser.pos] == '.') {
            parser.pos++;
            if (parser.pos >= parser.len || !is_digit(parser.data[parser.pos])) {
                parser.pos = token_start + 1; continue;
            }
            while (parser.pos < parser.len && is_digit(parser.data[parser.pos])) {
                if (digits < 18) magnitude = magnitude * 10u + (uint64_t)(parser.data[parser.pos] - '0');
                digits++; scale++; parser.pos++;
            }
        }
        if (parser.pos < parser.len && (parser.data[parser.pos] == 'e' || parser.data[parser.pos] == 'E')) {
            token_flags |= 2u; parser.pos++;
            if (parser.pos < parser.len && (parser.data[parser.pos] == '+' || parser.data[parser.pos] == '-')) parser.pos++;
            if (parser.pos >= parser.len || !is_digit(parser.data[parser.pos])) {
                parser.pos = token_start + 1; continue;
            }
            while (parser.pos < parser.len && is_digit(parser.data[parser.pos])) parser.pos++;
        }
        /* A token cut by the page boundary is emitted on the next fill. */
        if (parser.pos == limit && limit < len &&
            (is_digit(input[limit]) || input[limit] == '.' || input[limit] == 'e' || input[limit] == 'E' ||
             input[limit] == '+' || input[limit] == '-')) {
            parser.pos = token_start;
            break;
        }
        if (digits <= 18) token_flags |= 4u;
        token_flags |= ((uint64_t)scale << 8);
        int64_t base = count * 4;
        tokens[base] = (uint64_t)token_start;
        tokens[base + 1] = (uint64_t)parser.pos;
        tokens[base + 2] = magnitude;
        tokens[base + 3] = token_flags;
        count++;
    }
    *outNext = parser.pos;
    *outCount = count;
    *outError = -1;
    return YJ_JSON_SCAN_OK;
}

static int32_t push_token(uint64_t* tokens, int64_t tokenCap, int64_t* count, uint64_t token)
{
    if (*count >= tokenCap) {
        return YJ_JSON_SCAN_CAPACITY;
    }
    tokens[*count] = token;
    (*count)++;
    return YJ_JSON_SCAN_OK;
}

int32_t YJ_JSON_ScanTape(
    const uint8_t* input, int64_t len, int64_t start, uint32_t flags,
    uint64_t* tokens, int64_t tokenCap,
    int64_t* outNext, int64_t* outError)
{
    if (input == NULL || tokens == NULL || outNext == NULL || outError == NULL ||
        start < 0 || start > len || tokenCap < 0) {
        if (outError != NULL) {
            *outError = start;
        }
        return YJ_JSON_SCAN_ERROR;
    }
    YjParser parser = make_parser(input, len, start, flags);
    int64_t count = 0;
    while (parser.pos < parser.len) {
        uint8_t current = parser.data[parser.pos];
        uint8_t kind = 0;
        switch (current) {
            case '{':
                kind = TOKEN_OBJECT_START;
                break;
            case '}':
                kind = TOKEN_OBJECT_END;
                break;
            case '[':
                kind = TOKEN_ARRAY_START;
                break;
            case ']':
                kind = TOKEN_ARRAY_END;
                break;
            case ':':
                kind = TOKEN_COLON;
                break;
            case ',':
                kind = TOKEN_COMMA;
                break;
            case '"': {
                int64_t token_pos = parser.pos;
                int32_t status = skip_string(&parser, 0, NULL, NULL, NULL);
                if (status != YJ_JSON_SCAN_OK) {
                    return finish_status(&parser, status, outError);
                }
                status = push_token(tokens, tokenCap, &count, ((uint64_t)TOKEN_STRING << 56) | (uint64_t)token_pos);
                if (status != YJ_JSON_SCAN_OK) {
                    *outError = count + 1;
                    return status;
                }
                continue;
            }
            default:
                parser.pos++;
                continue;
        }
        int32_t status = push_token(tokens, tokenCap, &count, ((uint64_t)kind << 56) | (uint64_t)parser.pos);
        if (status != YJ_JSON_SCAN_OK) {
            *outError = count + 1;
            return status;
        }
        parser.pos++;
    }
    *outNext = parser.pos;
    *outError = count;
    return YJ_JSON_SCAN_OK;
}
