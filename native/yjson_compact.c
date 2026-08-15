#include "yjson_compact.h"

#include <limits.h>
#include <stddef.h>
#include <stdint.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(__linux__)
#include <sys/random.h>
#endif

#if UINTPTR_MAX > UINT64_MAX
#error "YJ_Compact opaque handles require uintptr_t to fit in uint64_t"
#endif

#define YJ_KEY_OWNED (UINT64_C(1) << 63)
#define YJ_KEY_OFFSET_MASK UINT64_C(0x7fffffff)
#define YJ_KEY_LENGTH_MASK UINT64_C(0xffffffff)
#define YJ_EMPTY_SLOT UINT64_MAX
#define YJ_LINEAR_DUPLICATE_LIMIT 8u
#define YJ_DEFAULT_ARENA_BLOCK (UINT64_C(4) * 1024u * 1024u)
#define YJ_SMALL_ARENA_BLOCK (UINT64_C(64) * 1024u)
#define YJ_MEDIUM_ARENA_BLOCK (UINT64_C(1) * 1024u * 1024u)
#define YJ_LOOKUP_CACHE_SIZE 64u

typedef struct YjArenaBlock {
    struct YjArenaBlock *next;
    uint64_t capacity;
    uint64_t used;
    uint8_t data[];
} YjArenaBlock;

typedef struct {
    YjArenaBlock *head;
    uint64_t used;
    uint64_t committed;
    uint64_t block_size;
} YjArena;

typedef struct {
    uint64_t payload;
    uint32_t aux;
    uint8_t kind;
    uint8_t reserved[3];
} YjNode;

typedef struct {
    const uint8_t *data;
    uint32_t length;
    uint32_t reserved;
} YjStringRef;

typedef struct {
    uint8_t kind;
    uint64_t payload;
} YjValue;

typedef struct {
    uint64_t *keys;
    uint8_t *kinds;
    uint64_t *values;
    uint32_t size;
    uint32_t capacity;
} YjTempObject;

typedef struct {
    uint32_t *items;
    uint32_t size;
    uint32_t capacity;
} YjTempArray;

typedef struct {
    uint64_t *slots;
    uint32_t capacity;
    uint32_t size;
} YjDuplicateTable;

typedef struct {
    uint64_t hash;
    uint32_t node;
    uint32_t position_plus_one;
    uint32_t key_length;
    uint32_t reserved;
} YjLookupCacheEntry;

typedef struct {
    uint8_t *source;
    uint64_t source_length;
    uint8_t source_owned;
    YjArena arena;
    YjNode *nodes;
    uint32_t node_count;
    uint32_t node_capacity;
    uint32_t *array_entries;
    uint32_t array_count;
    uint32_t array_capacity;
    uint64_t *object_keys;
    uint8_t *object_kinds;
    uint64_t *object_values;
    uint32_t object_count;
    uint32_t object_capacity;
    YjStringRef *strings;
    uint32_t string_count;
    uint32_t string_capacity;
    uint64_t scratch_current;
    uint64_t scratch_peak;
    uint64_t duplicate_scratch_peak;
    uint64_t persistent_used;
    uint64_t persistent_committed;
    uint64_t duplicate_lookups;
    uint64_t duplicate_inserts;
    uint64_t duplicate_probes;
    uint64_t duplicate_exact_equalities;
    uint64_t duplicate_rehash_entries;
    uint64_t duplicate_probe_histogram[32];
    uint32_t duplicate_max_probe;
    uint32_t duplicate_grow_count;
    uint32_t duplicate_final_capacity;
    uint32_t duplicate_largest_capacity;
    uint32_t duplicate_final_size;
    uint8_t duplicate_presized;
    uint64_t hash_seed;
    uint32_t root;
    atomic_flag lookup_lock;
    YjLookupCacheEntry lookup_cache[YJ_LOOKUP_CACHE_SIZE];
} YjDocument;

typedef struct {
    YjDocument *document;
    uint64_t position;
    uint32_t flags;
    int64_t max_depth;
    uint32_t error_code;
    int64_t error_offset;
} YjParser;

typedef struct {
    uint8_t *data;
    uint64_t size;
    uint64_t capacity;
    int failed;
} YjBuffer;

static int yj_add_overflow_u64(uint64_t a, uint64_t b, uint64_t *out) {
    if (a > UINT64_MAX - b) return 1;
    *out = a + b;
    return 0;
}

static int yj_mul_overflow_u64(uint64_t a, uint64_t b, uint64_t *out) {
    if (a != 0 && b > UINT64_MAX / a) return 1;
    *out = a * b;
    return 0;
}

static uint64_t yj_align8(uint64_t value) {
    return (value + 7u) & ~UINT64_C(7);
}

static void yj_set_error(YjParser *parser, uint32_t code, int64_t offset) {
    if (parser->error_code == YJ_COMPACT_OK) {
        parser->error_code = code;
        parser->error_offset = offset;
    }
}

static void yj_scratch_change(YjDocument *document, int64_t delta) {
    if (delta >= 0) {
        document->scratch_current += (uint64_t)delta;
        if (document->scratch_current > document->scratch_peak)
            document->scratch_peak = document->scratch_current;
    } else {
        uint64_t amount = (uint64_t)(-delta);
        document->scratch_current = amount > document->scratch_current
            ? 0 : document->scratch_current - amount;
    }
}

static void *yj_scratch_realloc(YjDocument *document, void *pointer,
                                uint64_t old_bytes, uint64_t new_bytes) {
    if (new_bytes > SIZE_MAX) return NULL;
    void *result = realloc(pointer, (size_t)new_bytes);
    if (result == NULL && new_bytes != 0) return NULL;
    if (new_bytes >= old_bytes) yj_scratch_change(document, (int64_t)(new_bytes - old_bytes));
    else yj_scratch_change(document, -(int64_t)(old_bytes - new_bytes));
    return result;
}

static void yj_scratch_free(YjDocument *document, void *pointer, uint64_t bytes) {
    free(pointer);
    yj_scratch_change(document, -(int64_t)bytes);
}

static void yj_promote_scratch(YjDocument *document, uint64_t bytes) {
    yj_scratch_change(document, -(int64_t)bytes);
    document->persistent_committed += bytes;
}

static void yj_arena_destroy(YjArena *arena) {
    YjArenaBlock *block = arena->head;
    while (block != NULL) {
        YjArenaBlock *next = block->next;
        free(block);
        block = next;
    }
    memset(arena, 0, sizeof(*arena));
}

static void *yj_arena_alloc(YjArena *arena, uint64_t size) {
    size = yj_align8(size == 0 ? 1 : size);
    YjArenaBlock *block = arena->head;
    if (block == NULL || block->capacity - block->used < size) {
        uint64_t capacity = arena->block_size;
        if (capacity < size) capacity = size;
        uint64_t allocation;
        if (yj_add_overflow_u64((uint64_t)offsetof(YjArenaBlock, data), capacity, &allocation) ||
            allocation > SIZE_MAX) return NULL;
        YjArenaBlock *next = (YjArenaBlock *)malloc((size_t)allocation);
        if (next == NULL) return NULL;
        next->next = block;
        next->capacity = capacity;
        next->used = 0;
        arena->head = next;
        arena->committed += allocation;
        block = next;
    }
    void *result = block->data + block->used;
    block->used += size;
    arena->used += size;
    return result;
}

static void yj_document_free(YjDocument *document) {
    if (document == NULL) return;
    if (document->source_owned) free(document->source);
    free(document->nodes);
    free(document->array_entries);
    free(document->object_keys);
    free(document->object_kinds);
    free(document->object_values);
    free(document->strings);
    yj_arena_destroy(&document->arena);
    free(document);
}

static int yj_reserve(void **storage, uint32_t *capacity, uint32_t required,
                      uint64_t width, YjDocument *document) {
    if (required <= *capacity) return 1;
    uint32_t next = *capacity == 0 ? 16u : *capacity;
    while (next < required) {
        if (next > UINT32_MAX / 2u) { next = required; break; }
        next *= 2u;
    }
    uint64_t bytes;
    if (yj_mul_overflow_u64(next, width, &bytes) || bytes > SIZE_MAX) return 0;
    void *replacement = realloc(*storage, (size_t)bytes);
    if (replacement == NULL) return 0;
    document->persistent_committed += (uint64_t)(next - *capacity) * width;
    *storage = replacement;
    *capacity = next;
    return 1;
}

static int yj_reserve_object(YjDocument *document, uint32_t required) {
    if (required <= document->object_capacity) return 1;
    uint32_t old_capacity = document->object_capacity;
    uint32_t next = old_capacity == 0 ? 16u : old_capacity;
    while (next < required) {
        if (next > UINT32_MAX / 2u) { next = required; break; }
        next *= 2u;
    }
    uint64_t keys_bytes, kinds_bytes, values_bytes;
    if (yj_mul_overflow_u64(next, sizeof(uint64_t), &keys_bytes) ||
        yj_mul_overflow_u64(next, sizeof(uint8_t), &kinds_bytes) ||
        yj_mul_overflow_u64(next, sizeof(uint64_t), &values_bytes) ||
        keys_bytes > SIZE_MAX || kinds_bytes > SIZE_MAX || values_bytes > SIZE_MAX) return 0;
    uint64_t *keys = (uint64_t *)realloc(document->object_keys, (size_t)keys_bytes);
    if (keys == NULL) return 0;
    document->object_keys = keys;
    uint8_t *kinds = (uint8_t *)realloc(document->object_kinds, (size_t)kinds_bytes);
    if (kinds == NULL) return 0;
    document->object_kinds = kinds;
    uint64_t *values = (uint64_t *)realloc(document->object_values, (size_t)values_bytes);
    if (values == NULL) return 0;
    document->object_values = values;
    document->persistent_committed += (uint64_t)(next - old_capacity) * 17u;
    document->object_capacity = next;
    return 1;
}

static int yj_add_string_ref(YjDocument *document, const uint8_t *data,
                             uint32_t length, uint32_t *out_index) {
    if (!yj_reserve((void **)&document->strings, &document->string_capacity,
                    document->string_count + 1u, sizeof(YjStringRef), document)) return 0;
    uint32_t index = document->string_count++;
    document->strings[index].data = data;
    document->strings[index].length = length;
    document->strings[index].reserved = 0;
    document->persistent_used += sizeof(YjStringRef);
    *out_index = index;
    return 1;
}

static int yj_add_node(YjDocument *document, YjValue value, uint32_t aux,
                       uint32_t *out_index) {
    if (!yj_reserve((void **)&document->nodes, &document->node_capacity,
                    document->node_count + 1u, sizeof(YjNode), document)) return 0;
    uint32_t index = document->node_count++;
    document->nodes[index].payload = value.payload;
    document->nodes[index].aux = aux;
    document->nodes[index].kind = value.kind;
    memset(document->nodes[index].reserved, 0, sizeof(document->nodes[index].reserved));
    document->persistent_used += sizeof(YjNode);
    *out_index = index;
    return 1;
}

static int yj_store_value(YjDocument *document, YjValue value, uint32_t *out_index) {
    if ((value.kind == YJ_COMPACT_ARRAY || value.kind == YJ_COMPACT_OBJECT) &&
        value.payload <= UINT32_MAX) {
        *out_index = (uint32_t)value.payload;
        return 1;
    }
    return yj_add_node(document, value, 0, out_index);
}

static void yj_skip_ws(YjParser *parser) {
    const uint8_t *source = parser->document->source;
    uint64_t length = parser->document->source_length;
    while (parser->position < length) {
        uint8_t c = source[parser->position];
        if (c != ' ' && c != '\t' && c != '\r' && c != '\n') break;
        parser->position++;
    }
}

static int yj_validate_utf8(const uint8_t *data, uint64_t length, uint64_t *bad) {
    uint64_t i = 0;
    while (i < length) {
        uint8_t c = data[i];
        if (c < 0x80) { i++; continue; }
        uint32_t cp;
        uint32_t need;
        if (c >= 0xC2 && c <= 0xDF) { cp = c & 0x1Fu; need = 1; }
        else if (c >= 0xE0 && c <= 0xEF) { cp = c & 0x0Fu; need = 2; }
        else if (c >= 0xF0 && c <= 0xF4) { cp = c & 0x07u; need = 3; }
        else { *bad = i; return 0; }
        if (i + need >= length) { *bad = i; return 0; }
        for (uint32_t j = 1; j <= need; j++) {
            uint8_t d = data[i + j];
            if ((d & 0xC0u) != 0x80u) { *bad = i + j; return 0; }
            cp = (cp << 6) | (d & 0x3Fu);
        }
        if ((need == 2 && cp < 0x800u) || (need == 3 && cp < 0x10000u) ||
            (cp >= 0xD800u && cp <= 0xDFFFu) || cp > 0x10FFFFu) {
            *bad = i; return 0;
        }
        i += need + 1u;
    }
    return 1;
}

static int yj_hex(uint8_t c) {
    if (c >= '0' && c <= '9') return (int)(c - '0');
    if (c >= 'a' && c <= 'f') return (int)(c - 'a' + 10);
    if (c >= 'A' && c <= 'F') return (int)(c - 'A' + 10);
    return -1;
}

static int yj_read_u16(const uint8_t *data, uint64_t end, uint64_t *position,
                       uint32_t *out) {
    if (*position + 4u > end) return 0;
    uint32_t value = 0;
    for (uint32_t i = 0; i < 4; i++) {
        int digit = yj_hex(data[*position + i]);
        if (digit < 0) return 0;
        value = (value << 4) | (uint32_t)digit;
    }
    *position += 4u;
    *out = value;
    return 1;
}

static uint32_t yj_write_utf8(uint8_t *output, uint32_t at, uint32_t cp) {
    if (cp <= 0x7Fu) output[at++] = (uint8_t)cp;
    else if (cp <= 0x7FFu) {
        output[at++] = (uint8_t)(0xC0u | (cp >> 6));
        output[at++] = (uint8_t)(0x80u | (cp & 0x3Fu));
    } else if (cp <= 0xFFFFu) {
        output[at++] = (uint8_t)(0xE0u | (cp >> 12));
        output[at++] = (uint8_t)(0x80u | ((cp >> 6) & 0x3Fu));
        output[at++] = (uint8_t)(0x80u | (cp & 0x3Fu));
    } else {
        output[at++] = (uint8_t)(0xF0u | (cp >> 18));
        output[at++] = (uint8_t)(0x80u | ((cp >> 12) & 0x3Fu));
        output[at++] = (uint8_t)(0x80u | ((cp >> 6) & 0x3Fu));
        output[at++] = (uint8_t)(0x80u | (cp & 0x3Fu));
    }
    return at;
}

static int yj_parse_string_bytes(YjParser *parser, const uint8_t **out_data,
                                 uint32_t *out_length, int *out_owned) {
    YjDocument *document = parser->document;
    const uint8_t *source = document->source;
    uint64_t length = document->source_length;
    if (parser->position >= length || source[parser->position] != '"') {
        yj_set_error(parser, YJ_COMPACT_PARSE_ERROR, (int64_t)parser->position);
        return 0;
    }
    uint64_t start = ++parser->position;
    uint64_t p = start;
    int escaped = 0;
    while (p < length) {
        uint8_t c = source[p];
        if (c == '"') break;
        if (c < 0x20u) {
            yj_set_error(parser, YJ_COMPACT_PARSE_ERROR, (int64_t)p); return 0;
        }
        if (c == '\\') { escaped = 1; p++; if (p >= length) break; }
        p++;
    }
    if (p >= length || source[p] != '"') {
        yj_set_error(parser, YJ_COMPACT_PARSE_ERROR, (int64_t)(p < length ? p : length));
        return 0;
    }
    uint64_t raw_length = p - start;
    if (raw_length > UINT32_MAX) {
        yj_set_error(parser, YJ_COMPACT_DOCUMENT_TOO_LARGE, (int64_t)start); return 0;
    }
    parser->position = p + 1u;
    if (!escaped) {
        uint64_t bad = 0;
        if (!yj_validate_utf8(source + start, raw_length, &bad)) {
            yj_set_error(parser, YJ_COMPACT_INVALID_UTF8, (int64_t)(start + bad)); return 0;
        }
        if ((parser->flags & YJ_COMPACT_MATERIALIZE_SOURCE) != 0) {
            uint8_t *copy = (uint8_t *)yj_arena_alloc(&document->arena, raw_length + 1u);
            if (copy == NULL) {
                yj_set_error(parser, YJ_COMPACT_OUT_OF_MEMORY, (int64_t)start); return 0;
            }
            if (raw_length != 0u) memcpy(copy, source + start, (size_t)raw_length);
            copy[raw_length] = 0;
            *out_data = copy;
            *out_owned = 1;
        } else {
            *out_data = source + start;
            *out_owned = 0;
        }
        *out_length = (uint32_t)raw_length;
        return 1;
    }
    uint8_t *decoded = (uint8_t *)yj_arena_alloc(&document->arena, raw_length + 1u);
    if (decoded == NULL) {
        yj_set_error(parser, YJ_COMPACT_OUT_OF_MEMORY, (int64_t)start); return 0;
    }
    uint32_t written = 0;
    uint64_t at = start;
    while (at < p) {
        uint8_t c = source[at++];
        if (c != '\\') { decoded[written++] = c; continue; }
        if (at >= p) { yj_set_error(parser, YJ_COMPACT_PARSE_ERROR, (int64_t)at); return 0; }
        uint8_t e = source[at++];
        switch (e) {
            case '"': decoded[written++] = '"'; break;
            case '\\': decoded[written++] = '\\'; break;
            case '/': decoded[written++] = '/'; break;
            case 'b': decoded[written++] = '\b'; break;
            case 'f': decoded[written++] = '\f'; break;
            case 'n': decoded[written++] = '\n'; break;
            case 'r': decoded[written++] = '\r'; break;
            case 't': decoded[written++] = '\t'; break;
            case 'u': {
                uint32_t cp;
                uint64_t escape_at = at;
                if (!yj_read_u16(source, p, &at, &cp)) {
                    yj_set_error(parser, YJ_COMPACT_PARSE_ERROR, (int64_t)escape_at); return 0;
                }
                if (cp >= 0xD800u && cp <= 0xDBFFu) {
                    if (at + 2u > p || source[at] != '\\' || source[at + 1u] != 'u') {
                        yj_set_error(parser, YJ_COMPACT_PARSE_ERROR, (int64_t)at); return 0;
                    }
                    at += 2u;
                    uint32_t low;
                    if (!yj_read_u16(source, p, &at, &low) || low < 0xDC00u || low > 0xDFFFu) {
                        yj_set_error(parser, YJ_COMPACT_PARSE_ERROR, (int64_t)(at >= 4u ? at - 4u : at)); return 0;
                    }
                    cp = 0x10000u + ((cp - 0xD800u) << 10) + (low - 0xDC00u);
                } else if (cp >= 0xDC00u && cp <= 0xDFFFu) {
                    yj_set_error(parser, YJ_COMPACT_PARSE_ERROR, (int64_t)escape_at); return 0;
                }
                written = yj_write_utf8(decoded, written, cp);
                break;
            }
            default:
                yj_set_error(parser, YJ_COMPACT_PARSE_ERROR, (int64_t)(at - 1u)); return 0;
        }
    }
    uint64_t bad = 0;
    if (!yj_validate_utf8(decoded, written, &bad)) {
        yj_set_error(parser, YJ_COMPACT_INVALID_UTF8, (int64_t)start); return 0;
    }
    decoded[written] = 0;
    *out_data = decoded;
    *out_length = written;
    *out_owned = 1;
    return 1;
}

static uint64_t yj_wymix(uint64_t a, uint64_t b) {
#if defined(__SIZEOF_INT128__)
    __uint128_t product = (__uint128_t)a * (__uint128_t)b;
    return (uint64_t)product ^ (uint64_t)(product >> 64);
#else
    uint64_t ah = a >> 32, al = (uint32_t)a;
    uint64_t bh = b >> 32, bl = (uint32_t)b;
    uint64_t high = ah * bh, mid0 = ah * bl, mid1 = al * bh, low = al * bl;
    uint64_t first = low + (mid0 << 32);
    uint64_t carry = first < low;
    uint64_t second = first + (mid1 << 32);
    carry += second < first;
    return second ^ (high + (mid0 >> 32) + (mid1 >> 32) + carry);
#endif
}

static uint64_t yj_read64(const uint8_t *p) {
    uint64_t value;
    memcpy(&value, p, sizeof(value));
    return value;
}

static uint64_t yj_hash(const uint8_t *data, uint32_t length, uint64_t secret) {
    const uint64_t s0 = UINT64_C(0xa0761d6478bd642f);
    const uint64_t s1 = UINT64_C(0xe7037ed1a0b428db);
    uint64_t seed = yj_wymix(s0 ^ secret, s1) ^ length;
    uint32_t at = 0;
    while (length - at >= 16u) {
        seed = yj_wymix(yj_read64(data + at) ^ s1, yj_read64(data + at + 8u) ^ seed);
        at += 16u;
    }
    uint64_t a = 0, b = 0;
    uint32_t remaining = length - at;
    if (remaining >= 8u) {
        a = yj_read64(data + at);
        memcpy(&b, data + at + remaining - 8u, 8u);
    } else if (remaining != 0) {
        for (uint32_t i = 0; i < remaining; i++) a = (a << 8) | data[at + i];
        b = remaining;
    }
    return yj_wymix(a ^ s0 ^ secret ^ length, b ^ seed ^ s1);
}

static uint64_t yj_random_seed(void) {
#if defined(YJ_TESTING)
    return UINT64_C(0x4f1bbcdc6762f315);
#elif defined(__linux__)
    uint64_t seed = 0;
    ssize_t count = getrandom(&seed, sizeof(seed), 0);
    if (count == (ssize_t)sizeof(seed) && seed != 0) return seed;
#endif
    FILE *stream = fopen("/dev/urandom", "rb");
    if (stream != NULL) {
        uint64_t seed = 0;
        size_t count = fread(&seed, 1, sizeof(seed), stream);
        fclose(stream);
        if (count == sizeof(seed) && seed != 0) return seed;
    }
    return yj_wymix((uint64_t)(uintptr_t)&stream,
                    UINT64_C(0xd6e8feb86659fd93));
}

static int yj_key_bytes(YjDocument *document, uint64_t key,
                        const uint8_t **out_data, uint32_t *out_length) {
    if ((key & YJ_KEY_OWNED) != 0) {
        uint64_t index = key & ~YJ_KEY_OWNED;
        if (index >= document->string_count) return 0;
        *out_data = document->strings[index].data;
        *out_length = document->strings[index].length;
        return 1;
    }
    uint64_t offset = (key >> 32) & YJ_KEY_OFFSET_MASK;
    uint64_t length = key & YJ_KEY_LENGTH_MASK;
    if (offset > document->source_length || length > document->source_length - offset) return 0;
    *out_data = document->source + offset;
    *out_length = (uint32_t)length;
    return 1;
}

static int yj_make_key(YjParser *parser, const uint8_t *data, uint32_t length,
                       int owned, uint64_t *out_key) {
    YjDocument *document = parser->document;
    if (!owned) {
        uint64_t offset = (uint64_t)(data - document->source);
        if (offset <= YJ_KEY_OFFSET_MASK) {
            *out_key = (offset << 32) | length;
            return 1;
        }
    }
    uint32_t index;
    if (!yj_add_string_ref(document, data, length, &index)) {
        yj_set_error(parser, YJ_COMPACT_OUT_OF_MEMORY, (int64_t)parser->position); return 0;
    }
    *out_key = YJ_KEY_OWNED | index;
    return 1;
}

static int yj_temp_array_push(YjParser *parser, YjTempArray *array, uint32_t value) {
    if (array->size == array->capacity) {
        uint32_t next = array->capacity == 0 ? 16u : array->capacity * 2u;
        if (next < array->capacity) { yj_set_error(parser, YJ_COMPACT_DOCUMENT_TOO_LARGE, (int64_t)parser->position); return 0; }
        uint64_t old_bytes = (uint64_t)array->capacity * sizeof(uint32_t);
        uint64_t new_bytes = (uint64_t)next * sizeof(uint32_t);
        void *replacement = yj_scratch_realloc(parser->document, array->items, old_bytes, new_bytes);
        if (replacement == NULL) { yj_set_error(parser, YJ_COMPACT_OUT_OF_MEMORY, (int64_t)parser->position); return 0; }
        array->items = (uint32_t *)replacement;
        array->capacity = next;
    }
    array->items[array->size++] = value;
    return 1;
}

static int yj_temp_object_reserve(YjParser *parser, YjTempObject *object, uint32_t required) {
    if (required <= object->capacity) return 1;
    uint32_t next = object->capacity == 0 ? 16u : object->capacity * 2u;
    while (next < required) {
        if (next > UINT32_MAX / 2u) { next = required; break; }
        next *= 2u;
    }
    uint64_t old_keys = (uint64_t)object->capacity * sizeof(uint64_t);
    uint64_t new_keys = (uint64_t)next * sizeof(uint64_t);
    void *keys = yj_scratch_realloc(parser->document, object->keys, old_keys, new_keys);
    if (keys == NULL) goto oom;
    object->keys = (uint64_t *)keys;
    void *kinds = yj_scratch_realloc(parser->document, object->kinds,
        object->capacity, next);
    if (kinds == NULL) goto oom;
    object->kinds = (uint8_t *)kinds;
    void *values = yj_scratch_realloc(parser->document, object->values, old_keys, new_keys);
    if (values == NULL) goto oom;
    object->values = (uint64_t *)values;
    object->capacity = next;
    return 1;
oom:
    yj_set_error(parser, YJ_COMPACT_OUT_OF_MEMORY, (int64_t)parser->position);
    return 0;
}

static int yj_key_equal(YjDocument *document, uint64_t left, uint64_t right) {
    const uint8_t *a, *b;
    uint32_t al, bl;
    if (!yj_key_bytes(document, left, &a, &al) || !yj_key_bytes(document, right, &b, &bl)) return 0;
    return al == bl && (al == 0 || memcmp(a, b, al) == 0);
}

static int yj_duplicate_grow(YjParser *parser, YjDuplicateTable *table,
                             YjTempObject *object, uint32_t capacity) {
    uint64_t bytes = (uint64_t)capacity * sizeof(uint64_t);
    uint64_t *slots = (uint64_t *)yj_scratch_realloc(parser->document, NULL, 0, bytes);
    if (slots == NULL) { yj_set_error(parser, YJ_COMPACT_OUT_OF_MEMORY, (int64_t)parser->position); return 0; }
    for (uint32_t i = 0; i < capacity; i++) slots[i] = YJ_EMPTY_SLOT;
    uint64_t *old = table->slots;
    uint32_t old_capacity = table->capacity;
    table->slots = slots;
    table->capacity = capacity;
    table->size = 0;
    if ((parser->flags & YJ_COMPACT_DUPLICATE_STATS) != 0) {
        parser->document->duplicate_grow_count++;
        if (capacity > parser->document->duplicate_largest_capacity)
            parser->document->duplicate_largest_capacity = capacity;
    }
    for (uint32_t position = 0; position < object->size; position++) {
        const uint8_t *data;
        uint32_t length;
        if (!yj_key_bytes(parser->document, object->keys[position], &data, &length)) return 0;
        uint32_t fingerprint = (uint32_t)yj_hash(data, length,
                                                 parser->document->hash_seed);
        uint32_t mask = capacity - 1u;
        uint32_t index = fingerprint & mask;
        uint32_t probes = 1;
        while (table->slots[index] != YJ_EMPTY_SLOT) {
            index = (index + 1u) & mask;
            probes++;
        }
        table->slots[index] = ((uint64_t)fingerprint << 32) | position;
        table->size++;
        if ((parser->flags & YJ_COMPACT_DUPLICATE_STATS) != 0) {
            parser->document->duplicate_rehash_entries++;
            parser->document->duplicate_probes += probes;
        }
    }
    if (bytes > parser->document->duplicate_scratch_peak)
        parser->document->duplicate_scratch_peak = bytes;
    if (old != NULL) yj_scratch_free(parser->document, old, (uint64_t)old_capacity * sizeof(uint64_t));
    return 1;
}

static int yj_duplicate_should_grow(YjParser *parser, YjDuplicateTable *table) {
    uint64_t next = (uint64_t)table->size + 1u;
    uint64_t capacity = table->capacity;
    if ((parser->flags & YJ_COMPACT_DUPLICATE_LOAD_50) != 0)
        return next * 2u >= capacity;
    if ((parser->flags & YJ_COMPACT_DUPLICATE_LOAD_625) != 0)
        return next * 8u >= capacity * 5u;
    if ((parser->flags & YJ_COMPACT_DUPLICATE_LOAD_875) != 0)
        return next * 8u >= capacity * 7u;
    /* Native malloc does not pay the GC-region penalty of the portable table.
       Growing at 50% keeps the final Flat64 capacity unchanged while sharply
       reducing the long linear-probe tail. */
    return next * 2u >= capacity;
}

static uint32_t yj_duplicate_initial_capacity(YjParser *parser) {
    if ((parser->flags & YJ_COMPACT_DUPLICATE_PRESIZE) == 0 ||
        parser->document->source_length < UINT64_C(1) * 1024u * 1024u) return 16u;
    uint64_t estimated = parser->document->source_length / 12u;
    if (estimated < 16u) return 16u;
    uint64_t required = estimated * 4u / 3u + 1u;
    uint32_t capacity = 16u;
    while (capacity < required && capacity <= UINT32_MAX / 2u) capacity *= 2u;
    if (capacity < required) return 16u;
    parser->document->duplicate_presized = 1u;
    return capacity;
}

static void yj_duplicate_record_probe(YjDocument *document, uint32_t probes) {
    document->duplicate_probes += probes;
    if (probes > document->duplicate_max_probe) document->duplicate_max_probe = probes;
    uint32_t bucket = probes >= 32u ? 31u : probes - 1u;
    document->duplicate_probe_histogram[bucket]++;
}

static int yj_duplicate_find(YjParser *parser, YjDuplicateTable *table,
                             YjTempObject *object, uint64_t key,
                             uint32_t *out_position, int *out_found) {
    const uint8_t *data;
    uint32_t length;
    if (!yj_key_bytes(parser->document, key, &data, &length)) return 0;
    if (object->size <= YJ_LINEAR_DUPLICATE_LIMIT && table->capacity == 0) {
        int collect_stats = (parser->flags & YJ_COMPACT_DUPLICATE_STATS) != 0;
        if (collect_stats) parser->document->duplicate_lookups++;
        uint32_t probes = 0;
        for (uint32_t i = 0; i < object->size; i++) {
            probes++;
            if (yj_key_equal(parser->document, object->keys[i], key)) {
                if (collect_stats) {
                    parser->document->duplicate_exact_equalities++;
                    yj_duplicate_record_probe(parser->document, probes);
                }
                *out_position = i; *out_found = 1; return 1;
            }
        }
        if (collect_stats) {
            if (probes != 0) yj_duplicate_record_probe(parser->document, probes);
            parser->document->duplicate_inserts++;
        }
        *out_found = 0; return 1;
    }
    if (table->capacity == 0 &&
        !yj_duplicate_grow(parser, table, object, yj_duplicate_initial_capacity(parser))) return 0;
    if (yj_duplicate_should_grow(parser, table)) {
        if (table->capacity > UINT32_MAX / 2u ||
            !yj_duplicate_grow(parser, table, object, table->capacity * 2u)) return 0;
    }
    uint32_t fingerprint = (uint32_t)yj_hash(data, length,
                                             parser->document->hash_seed);
    uint32_t mask = table->capacity - 1u;
    uint32_t index = fingerprint & mask;
    uint32_t probes = 0;
    int collect_stats = (parser->flags & YJ_COMPACT_DUPLICATE_STATS) != 0;
    if (collect_stats) parser->document->duplicate_lookups++;
    while (1) {
        probes++;
        uint64_t slot = table->slots[index];
        if (slot == YJ_EMPTY_SLOT) {
            table->slots[index] = ((uint64_t)fingerprint << 32) | object->size;
            table->size++;
            if (collect_stats) {
                parser->document->duplicate_inserts++;
                yj_duplicate_record_probe(parser->document, probes);
            }
            *out_found = 0;
            return 1;
        }
        uint32_t position = (uint32_t)slot;
        if ((uint32_t)(slot >> 32) == fingerprint && position < object->size &&
            yj_key_equal(parser->document, object->keys[position], key)) {
            if (collect_stats) {
                parser->document->duplicate_exact_equalities++;
                yj_duplicate_record_probe(parser->document, probes);
            }
            *out_position = position; *out_found = 1; return 1;
        }
        index = (index + 1u) & mask;
    }
}

static int yj_parse_value(YjParser *parser, int64_t depth, YjValue *out);

static int yj_parse_literal(YjParser *parser, const char *literal, uint8_t kind,
                            uint64_t payload, YjValue *out) {
    uint64_t size = strlen(literal);
    if (parser->position + size > parser->document->source_length ||
        memcmp(parser->document->source + parser->position, literal, size) != 0) {
        yj_set_error(parser, YJ_COMPACT_PARSE_ERROR, (int64_t)parser->position); return 0;
    }
    parser->position += size;
    out->kind = kind;
    out->payload = payload;
    return 1;
}

static int yj_parse_number(YjParser *parser, YjValue *out) {
    const uint8_t *source = parser->document->source;
    uint64_t length = parser->document->source_length;
    uint64_t start = parser->position;
    uint64_t p = start;
    int negative = 0, fractional = 0, exponent = 0;
    if (p < length && source[p] == '-') { negative = 1; p++; }
    if (p >= length) goto invalid;
    if (source[p] == '0') {
        p++;
        if (p < length && source[p] >= '0' && source[p] <= '9') goto invalid_at_p;
    } else if (source[p] >= '1' && source[p] <= '9') {
        do { p++; } while (p < length && source[p] >= '0' && source[p] <= '9');
    } else goto invalid;
    if (p < length && source[p] == '.') {
        fractional = 1; p++;
        if (p >= length || source[p] < '0' || source[p] > '9') goto invalid_at_p;
        do { p++; } while (p < length && source[p] >= '0' && source[p] <= '9');
    }
    if (p < length && (source[p] == 'e' || source[p] == 'E')) {
        exponent = 1; p++;
        if (p < length && (source[p] == '+' || source[p] == '-')) p++;
        if (p >= length || source[p] < '0' || source[p] > '9') goto invalid_at_p;
        do { p++; } while (p < length && source[p] >= '0' && source[p] <= '9');
    }
    if (p - start > UINT32_MAX) {
        yj_set_error(parser, YJ_COMPACT_DOCUMENT_TOO_LARGE, (int64_t)start); return 0;
    }
    parser->position = p;
    if ((parser->flags & YJ_COMPACT_PRESERVE_NUMBERS) == 0 && !fractional && !exponent) {
        uint64_t magnitude = 0;
        uint64_t digits = start + (negative ? 1u : 0u);
        int overflow = 0;
        for (uint64_t i = digits; i < p; i++) {
            uint32_t digit = source[i] - '0';
            if (magnitude > (UINT64_MAX - digit) / 10u) { overflow = 1; break; }
            magnitude = magnitude * 10u + digit;
        }
        uint64_t limit = negative ? (UINT64_C(1) << 63) : INT64_MAX;
        if (!overflow && magnitude <= limit) {
            int64_t value;
            if (negative) value = magnitude == (UINT64_C(1) << 63) ? INT64_MIN : -(int64_t)magnitude;
            else value = (int64_t)magnitude;
            out->kind = YJ_COMPACT_INT;
            memcpy(&out->payload, &value, sizeof(value));
            return 1;
        }
    }
    const uint8_t *number_data = source + start;
    if ((parser->flags & YJ_COMPACT_MATERIALIZE_SOURCE) != 0) {
        uint64_t number_length = p - start;
        uint8_t *copy = (uint8_t *)yj_arena_alloc(&parser->document->arena, number_length + 1u);
        if (copy == NULL) {
            yj_set_error(parser, YJ_COMPACT_OUT_OF_MEMORY, (int64_t)start); return 0;
        }
        memcpy(copy, number_data, (size_t)number_length);
        copy[number_length] = 0;
        number_data = copy;
    }
    uint32_t index;
    if (!yj_add_string_ref(parser->document, number_data, (uint32_t)(p - start), &index)) {
        yj_set_error(parser, YJ_COMPACT_OUT_OF_MEMORY, (int64_t)start); return 0;
    }
    out->kind = YJ_COMPACT_NUMBER;
    out->payload = index;
    return 1;
invalid_at_p:
    yj_set_error(parser, YJ_COMPACT_PARSE_ERROR, (int64_t)p); return 0;
invalid:
    yj_set_error(parser, YJ_COMPACT_PARSE_ERROR, (int64_t)start); return 0;
}

static int yj_parse_array(YjParser *parser, int64_t depth, YjValue *out) {
    parser->position++;
    yj_skip_ws(parser);
    YjTempArray local = {0};
    if (parser->position < parser->document->source_length &&
        parser->document->source[parser->position] == ']') {
        parser->position++;
    } else {
        while (1) {
            YjValue child;
            uint32_t node;
            if (!yj_parse_value(parser, depth + 1, &child) ||
                !yj_store_value(parser->document, child, &node) ||
                !yj_temp_array_push(parser, &local, node)) goto fail;
            yj_skip_ws(parser);
            if (parser->position >= parser->document->source_length) {
                yj_set_error(parser, YJ_COMPACT_PARSE_ERROR, (int64_t)parser->position); goto fail;
            }
            uint8_t c = parser->document->source[parser->position++];
            if (c == ']') break;
            if (c != ',') { yj_set_error(parser, YJ_COMPACT_PARSE_ERROR, (int64_t)(parser->position - 1u)); goto fail; }
            yj_skip_ws(parser);
        }
    }
    uint32_t start = parser->document->array_count;
    if (parser->document->array_count == 0u && parser->document->array_capacity == 0u &&
        parser->document->array_entries == NULL && local.items != NULL) {
        parser->document->array_entries = local.items;
        parser->document->array_count = local.size;
        parser->document->array_capacity = local.capacity;
        yj_promote_scratch(parser->document, (uint64_t)local.capacity * sizeof(uint32_t));
        local.items = NULL;
    } else {
        if (UINT32_MAX - parser->document->array_count < local.size ||
            !yj_reserve((void **)&parser->document->array_entries,
                        &parser->document->array_capacity,
                        parser->document->array_count + local.size,
                        sizeof(uint32_t), parser->document)) {
            yj_set_error(parser, YJ_COMPACT_OUT_OF_MEMORY, (int64_t)parser->position); goto fail;
        }
        if (local.size != 0) memcpy(parser->document->array_entries + start, local.items,
                                    (size_t)local.size * sizeof(uint32_t));
        parser->document->array_count += local.size;
    }
    parser->document->persistent_used += (uint64_t)local.size * sizeof(uint32_t);
    if (local.items != NULL) yj_scratch_free(parser->document, local.items,
        (uint64_t)local.capacity * sizeof(uint32_t));
    YjValue record = {YJ_COMPACT_ARRAY, start};
    uint32_t node;
    if (!yj_add_node(parser->document, record, local.size, &node)) {
        yj_set_error(parser, YJ_COMPACT_OUT_OF_MEMORY, (int64_t)parser->position); return 0;
    }
    out->kind = YJ_COMPACT_ARRAY;
    out->payload = node;
    return 1;
fail:
    if (local.items != NULL) yj_scratch_free(parser->document, local.items,
        (uint64_t)local.capacity * sizeof(uint32_t));
    return 0;
}

static int yj_parse_object(YjParser *parser, int64_t depth, YjValue *out) {
    parser->position++;
    yj_skip_ws(parser);
    YjTempObject local = {0};
    YjDuplicateTable duplicates = {0};
    if (parser->position < parser->document->source_length &&
        parser->document->source[parser->position] == '}') {
        parser->position++;
    } else {
        while (1) {
            const uint8_t *key_data;
            uint32_t key_length;
            int owned;
            uint64_t key;
            if (!yj_parse_string_bytes(parser, &key_data, &key_length, &owned) ||
                !yj_make_key(parser, key_data, key_length, owned, &key)) goto fail;
            yj_skip_ws(parser);
            if (parser->position >= parser->document->source_length ||
                parser->document->source[parser->position] != ':') {
                yj_set_error(parser, YJ_COMPACT_PARSE_ERROR, (int64_t)parser->position); goto fail;
            }
            parser->position++;
            YjValue value;
            if (!yj_parse_value(parser, depth + 1, &value)) goto fail;
            uint32_t existing = 0;
            int found = 0;
            if (!yj_duplicate_find(parser, &duplicates, &local, key, &existing, &found)) goto fail;
            uint64_t stored_payload = value.payload;
            if (value.kind == YJ_COMPACT_ARRAY || value.kind == YJ_COMPACT_OBJECT) {
                stored_payload = value.payload;
            }
            if (found) {
                if ((parser->flags & YJ_COMPACT_REJECT_DUPLICATES) != 0) {
                    yj_set_error(parser, YJ_COMPACT_DUPLICATE_KEY, (int64_t)parser->position); goto fail;
                }
                local.kinds[existing] = value.kind;
                local.values[existing] = stored_payload;
            } else {
                if (!yj_temp_object_reserve(parser, &local, local.size + 1u)) goto fail;
                local.keys[local.size] = key;
                local.kinds[local.size] = value.kind;
                local.values[local.size] = stored_payload;
                local.size++;
            }
            yj_skip_ws(parser);
            if (parser->position >= parser->document->source_length) {
                yj_set_error(parser, YJ_COMPACT_PARSE_ERROR, (int64_t)parser->position); goto fail;
            }
            uint8_t c = parser->document->source[parser->position++];
            if (c == '}') break;
            if (c != ',') { yj_set_error(parser, YJ_COMPACT_PARSE_ERROR, (int64_t)(parser->position - 1u)); goto fail; }
            yj_skip_ws(parser);
        }
    }
    if (duplicates.slots != NULL) yj_scratch_free(parser->document, duplicates.slots,
        (uint64_t)duplicates.capacity * sizeof(uint64_t));
    if ((parser->flags & YJ_COMPACT_DUPLICATE_STATS) != 0 &&
        duplicates.capacity > parser->document->duplicate_final_capacity) {
        parser->document->duplicate_final_capacity = duplicates.capacity;
        parser->document->duplicate_final_size = duplicates.size;
    }
    duplicates.slots = NULL;
    uint32_t start = parser->document->object_count;
    if (parser->document->object_count == 0u && parser->document->object_capacity == 0u &&
        parser->document->object_keys == NULL && local.keys != NULL) {
        parser->document->object_keys = local.keys;
        parser->document->object_kinds = local.kinds;
        parser->document->object_values = local.values;
        parser->document->object_count = local.size;
        parser->document->object_capacity = local.capacity;
        yj_promote_scratch(parser->document, (uint64_t)local.capacity * 17u);
        local.keys = NULL; local.kinds = NULL; local.values = NULL;
    } else {
        if (UINT32_MAX - parser->document->object_count < local.size ||
            !yj_reserve_object(parser->document, parser->document->object_count + local.size)) {
            yj_set_error(parser, YJ_COMPACT_OUT_OF_MEMORY, (int64_t)parser->position); goto fail;
        }
        if (local.size != 0) {
            memcpy(parser->document->object_keys + start, local.keys, (size_t)local.size * sizeof(uint64_t));
            memcpy(parser->document->object_kinds + start, local.kinds, local.size);
            memcpy(parser->document->object_values + start, local.values, (size_t)local.size * sizeof(uint64_t));
        }
        parser->document->object_count += local.size;
    }
    parser->document->persistent_used += (uint64_t)local.size * 17u;
    if (local.keys != NULL) yj_scratch_free(parser->document, local.keys,
        (uint64_t)local.capacity * sizeof(uint64_t));
    if (local.kinds != NULL) yj_scratch_free(parser->document, local.kinds, local.capacity);
    if (local.values != NULL) yj_scratch_free(parser->document, local.values,
        (uint64_t)local.capacity * sizeof(uint64_t));
    YjValue record = {YJ_COMPACT_OBJECT, start};
    uint32_t node;
    if (!yj_add_node(parser->document, record, local.size, &node)) {
        yj_set_error(parser, YJ_COMPACT_OUT_OF_MEMORY, (int64_t)parser->position); return 0;
    }
    out->kind = YJ_COMPACT_OBJECT;
    out->payload = node;
    return 1;
fail:
    if (duplicates.slots != NULL) yj_scratch_free(parser->document, duplicates.slots,
        (uint64_t)duplicates.capacity * sizeof(uint64_t));
    if (local.keys != NULL) yj_scratch_free(parser->document, local.keys,
        (uint64_t)local.capacity * sizeof(uint64_t));
    if (local.kinds != NULL) yj_scratch_free(parser->document, local.kinds, local.capacity);
    if (local.values != NULL) yj_scratch_free(parser->document, local.values,
        (uint64_t)local.capacity * sizeof(uint64_t));
    return 0;
}

static int yj_parse_value(YjParser *parser, int64_t depth, YjValue *out) {
    if (depth >= parser->max_depth) {
        yj_set_error(parser, YJ_COMPACT_MAX_DEPTH, (int64_t)parser->position); return 0;
    }
    yj_skip_ws(parser);
    if (parser->position >= parser->document->source_length) {
        yj_set_error(parser, YJ_COMPACT_PARSE_ERROR, (int64_t)parser->position); return 0;
    }
    uint8_t c = parser->document->source[parser->position];
    if (c == 'n') return yj_parse_literal(parser, "null", YJ_COMPACT_NULL, 0, out);
    if (c == 't') return yj_parse_literal(parser, "true", YJ_COMPACT_BOOL, 1, out);
    if (c == 'f') return yj_parse_literal(parser, "false", YJ_COMPACT_BOOL, 0, out);
    if (c == '"') {
        const uint8_t *data;
        uint32_t length, index;
        int owned;
        if (!yj_parse_string_bytes(parser, &data, &length, &owned) ||
            !yj_add_string_ref(parser->document, data, length, &index)) {
            if (parser->error_code == YJ_COMPACT_OK)
                yj_set_error(parser, YJ_COMPACT_OUT_OF_MEMORY, (int64_t)parser->position);
            return 0;
        }
        out->kind = YJ_COMPACT_STRING;
        out->payload = index;
        return 1;
    }
    if (c == '[') return yj_parse_array(parser, depth, out);
    if (c == '{') return yj_parse_object(parser, depth, out);
    if (c == '-' || (c >= '0' && c <= '9')) return yj_parse_number(parser, out);
    yj_set_error(parser, YJ_COMPACT_PARSE_ERROR, (int64_t)parser->position);
    return 0;
}

static YjDocument *yj_from_handle(uint64_t handle) {
    return (YjDocument *)(uintptr_t)handle;
}

static int yj_node(YjDocument *document, uint32_t node, YjNode **out) {
    if (document == NULL) return YJ_COMPACT_CLOSED;
    if (node >= document->node_count) return YJ_COMPACT_BOUNDS_ERROR;
    *out = &document->nodes[node];
    return YJ_COMPACT_OK;
}

int32_t YJ_Compact_Parse(const uint8_t *input, int64_t length,
                        uint32_t flags, int64_t max_depth,
                        uint64_t *out_handle, uint32_t *out_root,
                        uint32_t *out_error_code, int64_t *out_error_offset) {
    if (out_handle == NULL || out_root == NULL || out_error_code == NULL || out_error_offset == NULL)
        return YJ_COMPACT_PARSE_ERROR;
    *out_handle = 0; *out_root = 0; *out_error_code = YJ_COMPACT_OK; *out_error_offset = -1;
    if (input == NULL || length < 0 || max_depth <= 0) {
        *out_error_code = YJ_COMPACT_PARSE_ERROR; *out_error_offset = 0; return YJ_COMPACT_PARSE_ERROR;
    }
    YjDocument *document = (YjDocument *)calloc(1, sizeof(YjDocument));
    if (document == NULL) { *out_error_code = YJ_COMPACT_OUT_OF_MEMORY; return YJ_COMPACT_OUT_OF_MEMORY; }
    atomic_flag_clear(&document->lookup_lock);
    document->hash_seed = yj_random_seed();
    document->arena.block_size = (uint64_t)length <= UINT64_C(1) * 1024u * 1024u
        ? YJ_SMALL_ARENA_BLOCK
        : ((uint64_t)length <= UINT64_C(16) * 1024u * 1024u
            ? YJ_MEDIUM_ARENA_BLOCK : YJ_DEFAULT_ARENA_BLOCK);
    document->source_length = (uint64_t)length;
    if ((flags & YJ_COMPACT_MATERIALIZE_SOURCE) != 0) {
        document->source = (uint8_t *)(uintptr_t)input;
        document->source_owned = 0u;
    } else if (length != 0) {
        document->source = (uint8_t *)malloc((size_t)length);
        if (document->source == NULL) {
            yj_document_free(document); *out_error_code = YJ_COMPACT_OUT_OF_MEMORY; return YJ_COMPACT_OUT_OF_MEMORY;
        }
        memcpy(document->source, input, (size_t)length);
        document->source_owned = 1u;
    }
    document->persistent_used = document->source_owned ? (uint64_t)length : 0u;
    document->persistent_committed = document->source_owned ? (uint64_t)length : 0u;
    YjParser parser = {document, 0, flags, max_depth, YJ_COMPACT_OK, -1};
    YjValue root_value;
    uint32_t root;
    if (!yj_parse_value(&parser, 0, &root_value)) goto error;
    yj_skip_ws(&parser);
    if (parser.position != document->source_length) {
        yj_set_error(&parser, YJ_COMPACT_PARSE_ERROR, (int64_t)parser.position); goto error;
    }
    if (!yj_store_value(document, root_value, &root)) {
        yj_set_error(&parser, YJ_COMPACT_OUT_OF_MEMORY, (int64_t)parser.position); goto error;
    }
    document->root = root;
    if ((flags & YJ_COMPACT_MATERIALIZE_SOURCE) != 0) document->source = NULL;
    *out_handle = (uint64_t)(uintptr_t)document;
    *out_root = root;
    return YJ_COMPACT_OK;
error:
    *out_error_code = parser.error_code == YJ_COMPACT_OK ? YJ_COMPACT_PARSE_ERROR : parser.error_code;
    *out_error_offset = parser.error_offset;
    yj_document_free(document);
    return (int32_t)*out_error_code;
}

void YJ_Compact_Free(uint64_t handle) { yj_document_free(yj_from_handle(handle)); }

int32_t YJ_Compact_Kind(uint64_t handle, uint32_t node, uint32_t *out_kind) {
    YjNode *value; int result = yj_node(yj_from_handle(handle), node, &value);
    if (result == YJ_COMPACT_OK && out_kind != NULL) *out_kind = value->kind;
    return result;
}

int32_t YJ_Compact_Size(uint64_t handle, uint32_t node, uint64_t *out_size) {
    YjNode *value; int result = yj_node(yj_from_handle(handle), node, &value);
    if (result != YJ_COMPACT_OK) return result;
    if (out_size == NULL) return YJ_COMPACT_PARSE_ERROR;
    *out_size = (value->kind == YJ_COMPACT_ARRAY || value->kind == YJ_COMPACT_OBJECT) ? value->aux : 0;
    return YJ_COMPACT_OK;
}

int32_t YJ_Compact_GetInt(uint64_t handle, uint32_t node, int64_t *out_value) {
    YjNode *value; int result = yj_node(yj_from_handle(handle), node, &value);
    if (result != YJ_COMPACT_OK) return result;
    if (value->kind != YJ_COMPACT_INT || out_value == NULL) return YJ_COMPACT_TYPE_ERROR;
    memcpy(out_value, &value->payload, sizeof(*out_value));
    return YJ_COMPACT_OK;
}

int32_t YJ_Compact_GetBool(uint64_t handle, uint32_t node, uint32_t *out_value) {
    YjNode *value; int result = yj_node(yj_from_handle(handle), node, &value);
    if (result != YJ_COMPACT_OK) return result;
    if (value->kind != YJ_COMPACT_BOOL || out_value == NULL) return YJ_COMPACT_TYPE_ERROR;
    *out_value = value->payload != 0;
    return YJ_COMPACT_OK;
}

static int yj_text(YjDocument *document, YjNode *node, const uint8_t **data, uint32_t *length) {
    if (node->kind != YJ_COMPACT_STRING && node->kind != YJ_COMPACT_NUMBER) return YJ_COMPACT_TYPE_ERROR;
    if (node->payload >= document->string_count) return YJ_COMPACT_BOUNDS_ERROR;
    *data = document->strings[node->payload].data;
    *length = document->strings[node->payload].length;
    return YJ_COMPACT_OK;
}

int32_t YJ_Compact_GetTextSize(uint64_t handle, uint32_t node, uint64_t *out_size) {
    YjDocument *document = yj_from_handle(handle); YjNode *value;
    int result = yj_node(document, node, &value); const uint8_t *data; uint32_t length;
    if (result == YJ_COMPACT_OK) result = yj_text(document, value, &data, &length);
    if (result == YJ_COMPACT_OK && out_size != NULL) *out_size = length;
    return result;
}

int32_t YJ_Compact_CopyText(uint64_t handle, uint32_t node,
                           uint8_t *output, uint64_t output_capacity,
                           uint64_t *out_written) {
    YjDocument *document = yj_from_handle(handle); YjNode *value;
    const uint8_t *data; uint32_t length;
    int result = yj_node(document, node, &value);
    if (result == YJ_COMPACT_OK) result = yj_text(document, value, &data, &length);
    if (result != YJ_COMPACT_OK) return result;
    if (out_written == NULL) return YJ_COMPACT_PARSE_ERROR;
    *out_written = length;
    if (output_capacity < length || (length != 0 && output == NULL)) return YJ_COMPACT_BOUNDS_ERROR;
    if (length != 0) memcpy(output, data, length);
    return YJ_COMPACT_OK;
}

int32_t YJ_Compact_ArrayGet(uint64_t handle, uint32_t node,
                           uint64_t index, uint32_t *out_node) {
    YjDocument *document = yj_from_handle(handle); YjNode *value;
    int result = yj_node(document, node, &value);
    if (result != YJ_COMPACT_OK) return result;
    if (value->kind != YJ_COMPACT_ARRAY) return YJ_COMPACT_TYPE_ERROR;
    if (index >= value->aux || out_node == NULL) return YJ_COMPACT_BOUNDS_ERROR;
    *out_node = document->array_entries[value->payload + index];
    return YJ_COMPACT_OK;
}

static int yj_object_entry(YjDocument *document, YjNode *node, uint64_t index,
                           uint32_t *out_kind, uint64_t *out_payload) {
    if (node->kind != YJ_COMPACT_OBJECT) return YJ_COMPACT_TYPE_ERROR;
    if (index >= node->aux) return YJ_COMPACT_BOUNDS_ERROR;
    uint64_t position = node->payload + index;
    *out_kind = document->object_kinds[position];
    *out_payload = document->object_values[position];
    return YJ_COMPACT_OK;
}

int32_t YJ_Compact_ObjectEntry(uint64_t handle, uint32_t node, uint64_t index,
                              uint32_t *out_value_kind, uint64_t *out_value_payload,
                              uint64_t *out_key_size) {
    YjDocument *document = yj_from_handle(handle); YjNode *value;
    int result = yj_node(document, node, &value);
    if (result != YJ_COMPACT_OK || out_value_kind == NULL || out_value_payload == NULL ||
        out_key_size == NULL) return result;
    if (value->kind != YJ_COMPACT_OBJECT || index >= value->aux) return YJ_COMPACT_BOUNDS_ERROR;
    const uint8_t *key_data; uint32_t key_length;
    if (!yj_key_bytes(document, document->object_keys[value->payload + index], &key_data, &key_length))
        return YJ_COMPACT_BOUNDS_ERROR;
    *out_key_size = key_length;
    return yj_object_entry(document, value, index, out_value_kind, out_value_payload);
}

int32_t YJ_Compact_CopyObjectKey(uint64_t handle, uint32_t node, uint64_t index,
                                uint8_t *output, uint64_t output_capacity,
                                uint64_t *out_written) {
    YjDocument *document = yj_from_handle(handle); YjNode *value;
    int result = yj_node(document, node, &value);
    if (result != YJ_COMPACT_OK) return result;
    if (value->kind != YJ_COMPACT_OBJECT || index >= value->aux || out_written == NULL)
        return YJ_COMPACT_BOUNDS_ERROR;
    const uint8_t *data; uint32_t length;
    if (!yj_key_bytes(document, document->object_keys[value->payload + index], &data, &length))
        return YJ_COMPACT_BOUNDS_ERROR;
    *out_written = length;
    if (output_capacity < length || (length != 0 && output == NULL)) return YJ_COMPACT_BOUNDS_ERROR;
    if (length != 0) memcpy(output, data, length);
    return YJ_COMPACT_OK;
}

int32_t YJ_Compact_ObjectLookup(uint64_t handle, uint32_t node,
                               const uint8_t *key, uint64_t key_length,
                               uint32_t *out_value_kind, uint64_t *out_value_payload,
                               uint32_t *out_found) {
    YjDocument *document = yj_from_handle(handle); YjNode *value;
    int result = yj_node(document, node, &value);
    if (result != YJ_COMPACT_OK) return result;
    if (value->kind != YJ_COMPACT_OBJECT || key_length > UINT32_MAX ||
        out_value_kind == NULL || out_value_payload == NULL || out_found == NULL ||
        (key_length != 0 && key == NULL)) return YJ_COMPACT_TYPE_ERROR;
    uint64_t hash = yj_hash(key, (uint32_t)key_length, document->hash_seed);
    uint32_t cache_index = (uint32_t)(hash ^ node) & (YJ_LOOKUP_CACHE_SIZE - 1u);
    while (atomic_flag_test_and_set_explicit(&document->lookup_lock, memory_order_acquire)) { }
    YjLookupCacheEntry cached = document->lookup_cache[cache_index];
    atomic_flag_clear_explicit(&document->lookup_lock, memory_order_release);
    if (cached.position_plus_one != 0u && cached.hash == hash && cached.node == node &&
        cached.key_length == key_length && cached.position_plus_one - 1u < value->aux) {
        uint32_t position = cached.position_plus_one - 1u;
        const uint8_t *data; uint32_t length;
        if (yj_key_bytes(document, document->object_keys[value->payload + position], &data, &length) &&
            length == key_length && (length == 0u || memcmp(data, key, length) == 0)) {
            *out_found = 1;
            return yj_object_entry(document, value, position, out_value_kind, out_value_payload);
        }
    }
    for (uint32_t i = 0; i < value->aux; i++) {
        const uint8_t *data; uint32_t length;
        if (!yj_key_bytes(document, document->object_keys[value->payload + i], &data, &length))
            return YJ_COMPACT_BOUNDS_ERROR;
        if (length == key_length && (length == 0 || memcmp(data, key, length) == 0)) {
            YjLookupCacheEntry entry = {hash, node, i + 1u, (uint32_t)key_length, 0u};
            while (atomic_flag_test_and_set_explicit(&document->lookup_lock, memory_order_acquire)) { }
            document->lookup_cache[cache_index] = entry;
            atomic_flag_clear_explicit(&document->lookup_lock, memory_order_release);
            *out_found = 1;
            return yj_object_entry(document, value, i, out_value_kind, out_value_payload);
        }
    }
    *out_found = 0; *out_value_kind = 0; *out_value_payload = 0;
    return YJ_COMPACT_OK;
}

int32_t YJ_Compact_GetStringRefSize(uint64_t handle, uint64_t string_ref,
                                   uint64_t *out_size) {
    YjDocument *document = yj_from_handle(handle);
    if (document == NULL) return YJ_COMPACT_CLOSED;
    if (string_ref >= document->string_count || out_size == NULL) return YJ_COMPACT_BOUNDS_ERROR;
    *out_size = document->strings[string_ref].length;
    return YJ_COMPACT_OK;
}

int32_t YJ_Compact_CopyStringRef(uint64_t handle, uint64_t string_ref,
                                uint8_t *output, uint64_t output_capacity,
                                uint64_t *out_written) {
    YjDocument *document = yj_from_handle(handle);
    if (document == NULL) return YJ_COMPACT_CLOSED;
    if (string_ref >= document->string_count || out_written == NULL) return YJ_COMPACT_BOUNDS_ERROR;
    YjStringRef *text = &document->strings[string_ref];
    *out_written = text->length;
    if (output_capacity < text->length || (text->length != 0 && output == NULL))
        return YJ_COMPACT_BOUNDS_ERROR;
    if (text->length != 0) memcpy(output, text->data, text->length);
    return YJ_COMPACT_OK;
}

uint64_t YJ_Compact_TraversalChecksum(uint64_t handle) {
    YjDocument *document = yj_from_handle(handle);
    if (document == NULL) return 0;
    uint64_t result = 0;
    for (uint32_t i = 0; i < document->node_count; i++)
        result ^= document->nodes[i].payload ^ document->nodes[i].aux ^ document->nodes[i].kind;
    for (uint32_t i = 0; i < document->object_count; i++)
        result ^= document->object_keys[i] ^ document->object_values[i] ^ document->object_kinds[i];
    return result & UINT64_C(0x7fffffff);
}

static int yj_buffer_reserve(YjBuffer *buffer, uint64_t extra) {
    uint64_t required;
    if (yj_add_overflow_u64(buffer->size, extra, &required) || required > SIZE_MAX) return 0;
    if (required <= buffer->capacity) return 1;
    uint64_t next = buffer->capacity == 0 ? 256u : buffer->capacity;
    while (next < required) {
        if (next > UINT64_MAX / 2u) { next = required; break; }
        next *= 2u;
    }
    void *replacement = realloc(buffer->data, (size_t)next);
    if (replacement == NULL) return 0;
    buffer->data = (uint8_t *)replacement;
    buffer->capacity = next;
    return 1;
}

static void yj_buffer_write(YjBuffer *buffer, const uint8_t *data, uint64_t length) {
    if (buffer->failed || !yj_buffer_reserve(buffer, length)) { buffer->failed = 1; return; }
    if (length != 0) memcpy(buffer->data + buffer->size, data, (size_t)length);
    buffer->size += length;
}

static void yj_buffer_byte(YjBuffer *buffer, uint8_t value) { yj_buffer_write(buffer, &value, 1); }

static void yj_serialize_string(YjBuffer *buffer, const uint8_t *data, uint32_t length) {
    static const char hex[] = "0123456789abcdef";
    yj_buffer_byte(buffer, '"');
    for (uint32_t i = 0; i < length; i++) {
        uint8_t c = data[i];
        switch (c) {
            case '"': yj_buffer_write(buffer, (const uint8_t *)"\\\"", 2); break;
            case '\\': yj_buffer_write(buffer, (const uint8_t *)"\\\\", 2); break;
            case '\b': yj_buffer_write(buffer, (const uint8_t *)"\\b", 2); break;
            case '\f': yj_buffer_write(buffer, (const uint8_t *)"\\f", 2); break;
            case '\n': yj_buffer_write(buffer, (const uint8_t *)"\\n", 2); break;
            case '\r': yj_buffer_write(buffer, (const uint8_t *)"\\r", 2); break;
            case '\t': yj_buffer_write(buffer, (const uint8_t *)"\\t", 2); break;
            default:
                if (c < 0x20u) {
                    uint8_t escaped[6] = {'\\', 'u', '0', '0', (uint8_t)hex[c >> 4], (uint8_t)hex[c & 15u]};
                    yj_buffer_write(buffer, escaped, 6);
                } else yj_buffer_byte(buffer, c);
        }
    }
    yj_buffer_byte(buffer, '"');
}

static void yj_serialize_node(YjDocument *document, uint32_t node_index, YjBuffer *buffer) {
    if (buffer->failed || node_index >= document->node_count) { buffer->failed = 1; return; }
    YjNode *node = &document->nodes[node_index];
    switch (node->kind) {
        case YJ_COMPACT_NULL: yj_buffer_write(buffer, (const uint8_t *)"null", 4); break;
        case YJ_COMPACT_BOOL:
            if (node->payload) yj_buffer_write(buffer, (const uint8_t *)"true", 4);
            else yj_buffer_write(buffer, (const uint8_t *)"false", 5);
            break;
        case YJ_COMPACT_INT: {
            int64_t value; char text[32]; int count = 0; memcpy(&value, &node->payload, sizeof(value));
            uint64_t magnitude = value < 0 ? (uint64_t)(-(value + 1)) + 1u : (uint64_t)value;
            do { text[count++] = (char)('0' + magnitude % 10u); magnitude /= 10u; } while (magnitude != 0);
            if (value < 0) text[count++] = '-';
            while (count != 0) yj_buffer_byte(buffer, (uint8_t)text[--count]);
            break;
        }
        case YJ_COMPACT_NUMBER: {
            YjStringRef *text = &document->strings[node->payload];
            yj_buffer_write(buffer, text->data, text->length); break;
        }
        case YJ_COMPACT_STRING: {
            YjStringRef *text = &document->strings[node->payload];
            yj_serialize_string(buffer, text->data, text->length); break;
        }
        case YJ_COMPACT_ARRAY:
            yj_buffer_byte(buffer, '[');
            for (uint32_t i = 0; i < node->aux; i++) {
                if (i != 0) yj_buffer_byte(buffer, ',');
                yj_serialize_node(document, document->array_entries[node->payload + i], buffer);
            }
            yj_buffer_byte(buffer, ']');
            break;
        case YJ_COMPACT_OBJECT:
            yj_buffer_byte(buffer, '{');
            for (uint32_t i = 0; i < node->aux; i++) {
                if (i != 0) yj_buffer_byte(buffer, ',');
                uint64_t position = node->payload + i;
                const uint8_t *key; uint32_t key_length;
                if (!yj_key_bytes(document, document->object_keys[position], &key, &key_length)) { buffer->failed = 1; return; }
                yj_serialize_string(buffer, key, key_length);
                yj_buffer_byte(buffer, ':');
                YjValue inline_value = {document->object_kinds[position], document->object_values[position]};
                if (inline_value.kind == YJ_COMPACT_ARRAY || inline_value.kind == YJ_COMPACT_OBJECT) {
                    yj_serialize_node(document, (uint32_t)inline_value.payload, buffer);
                } else {
                    switch (inline_value.kind) {
                        case YJ_COMPACT_NULL: yj_buffer_write(buffer, (const uint8_t *)"null", 4); break;
                        case YJ_COMPACT_BOOL: yj_buffer_write(buffer, (const uint8_t *)(inline_value.payload ? "true" : "false"), inline_value.payload ? 4 : 5); break;
                        case YJ_COMPACT_INT: {
                            int64_t v; char t[32]; int n = 0; memcpy(&v, &inline_value.payload, 8);
                            uint64_t m = v < 0 ? (uint64_t)(-(v + 1)) + 1u : (uint64_t)v;
                            do { t[n++] = (char)('0' + m % 10u); m /= 10u; } while (m != 0);
                            if (v < 0) t[n++] = '-';
                            while (n) yj_buffer_byte(buffer, (uint8_t)t[--n]);
                            break;
                        }
                        case YJ_COMPACT_NUMBER: { YjStringRef *s = &document->strings[inline_value.payload]; yj_buffer_write(buffer, s->data, s->length); break; }
                        case YJ_COMPACT_STRING: { YjStringRef *s = &document->strings[inline_value.payload]; yj_serialize_string(buffer, s->data, s->length); break; }
                        default: buffer->failed = 1;
                    }
                }
            }
            yj_buffer_byte(buffer, '}');
            break;
        default: buffer->failed = 1;
    }
}

int32_t YJ_Compact_Serialize(uint64_t handle, uint8_t *output,
                            uint64_t output_capacity, uint64_t *out_written) {
    YjDocument *document = yj_from_handle(handle);
    if (document == NULL || out_written == NULL) return YJ_COMPACT_CLOSED;
    YjBuffer buffer = {0};
    yj_serialize_node(document, document->root, &buffer);
    if (buffer.failed) { free(buffer.data); return YJ_COMPACT_OUT_OF_MEMORY; }
    *out_written = buffer.size;
    if (output == NULL || output_capacity < buffer.size) { free(buffer.data); return YJ_COMPACT_BOUNDS_ERROR; }
    if (buffer.size != 0) memcpy(output, buffer.data, (size_t)buffer.size);
    free(buffer.data);
    return YJ_COMPACT_OK;
}

int32_t YJ_Compact_SerializeAlloc(uint64_t handle, uint64_t *out_buffer_handle,
                                 uint64_t *out_size) {
    YjDocument *document = yj_from_handle(handle);
    if (document == NULL || out_buffer_handle == NULL || out_size == NULL) return YJ_COMPACT_CLOSED;
    *out_buffer_handle = 0u;
    *out_size = 0u;
    YjBuffer *buffer = (YjBuffer *)calloc(1u, sizeof(YjBuffer));
    if (buffer == NULL) return YJ_COMPACT_OUT_OF_MEMORY;
    yj_serialize_node(document, document->root, buffer);
    if (buffer->failed) {
        free(buffer->data);
        free(buffer);
        return YJ_COMPACT_OUT_OF_MEMORY;
    }
    *out_size = buffer->size;
    *out_buffer_handle = (uint64_t)(uintptr_t)buffer;
    return YJ_COMPACT_OK;
}

static void yj_tape_u32(YjBuffer *buffer, uint32_t value) {
    uint8_t bytes[4] = {
        (uint8_t)value, (uint8_t)(value >> 8),
        (uint8_t)(value >> 16), (uint8_t)(value >> 24)
    };
    yj_buffer_write(buffer, bytes, sizeof(bytes));
}

static void yj_tape_u64(YjBuffer *buffer, uint64_t value) {
    uint8_t bytes[8];
    for (uint32_t i = 0; i < 8u; i++) bytes[i] = (uint8_t)(value >> (i * 8u));
    yj_buffer_write(buffer, bytes, sizeof(bytes));
}

static void yj_tape_value(YjDocument *document, YjValue value, YjBuffer *buffer);

static void yj_tape_node(YjDocument *document, uint32_t node, YjBuffer *buffer) {
    if (node >= document->node_count) { buffer->failed = 1; return; }
    YjNode *stored = &document->nodes[node];
    YjValue value = {stored->kind,
        (stored->kind == YJ_COMPACT_ARRAY || stored->kind == YJ_COMPACT_OBJECT)
            ? node : stored->payload};
    yj_tape_value(document, value, buffer);
}

static void yj_tape_value(YjDocument *document, YjValue value, YjBuffer *buffer) {
    yj_buffer_byte(buffer, value.kind);
    switch (value.kind) {
        case YJ_COMPACT_NULL: break;
        case YJ_COMPACT_BOOL: yj_buffer_byte(buffer, value.payload != 0u); break;
        case YJ_COMPACT_INT: yj_tape_u64(buffer, value.payload); break;
        case YJ_COMPACT_NUMBER:
        case YJ_COMPACT_STRING: {
            if (value.payload >= document->string_count) { buffer->failed = 1; return; }
            YjStringRef *text = &document->strings[value.payload];
            yj_tape_u32(buffer, text->length);
            yj_buffer_write(buffer, text->data, text->length);
            break;
        }
        case YJ_COMPACT_ARRAY: {
            if (value.payload >= document->node_count) { buffer->failed = 1; return; }
            YjNode *array = &document->nodes[value.payload];
            yj_tape_u32(buffer, array->aux);
            for (uint32_t i = 0; i < array->aux; i++)
                yj_tape_node(document, document->array_entries[array->payload + i], buffer);
            break;
        }
        case YJ_COMPACT_OBJECT: {
            if (value.payload >= document->node_count) { buffer->failed = 1; return; }
            YjNode *object = &document->nodes[value.payload];
            yj_tape_u32(buffer, object->aux);
            for (uint32_t i = 0; i < object->aux; i++) {
                uint64_t position = object->payload + i;
                const uint8_t *key; uint32_t key_length;
                if (!yj_key_bytes(document, document->object_keys[position], &key, &key_length)) {
                    buffer->failed = 1; return;
                }
                yj_tape_u32(buffer, key_length);
                yj_buffer_write(buffer, key, key_length);
                YjValue child = {document->object_kinds[position], document->object_values[position]};
                yj_tape_value(document, child, buffer);
            }
            break;
        }
        default: buffer->failed = 1;
    }
}

int32_t YJ_Compact_ExportTapeAlloc(uint64_t handle, uint64_t *out_buffer_handle,
                                  uint64_t *out_size) {
    YjDocument *document = yj_from_handle(handle);
    if (document == NULL || out_buffer_handle == NULL || out_size == NULL)
        return YJ_COMPACT_CLOSED;
    YjBuffer *buffer = (YjBuffer *)calloc(1u, sizeof(YjBuffer));
    if (buffer == NULL) return YJ_COMPACT_OUT_OF_MEMORY;
    yj_buffer_write(buffer, (const uint8_t *)"YJT1", 4u);
    yj_tape_node(document, document->root, buffer);
    if (buffer->failed) {
        free(buffer->data); free(buffer); return YJ_COMPACT_OUT_OF_MEMORY;
    }
    *out_buffer_handle = (uint64_t)(uintptr_t)buffer;
    *out_size = buffer->size;
    return YJ_COMPACT_OK;
}

int32_t YJ_Compact_CopyOwnedBuffer(uint64_t buffer_handle, uint8_t *output,
                                  uint64_t output_capacity) {
    YjBuffer *buffer = (YjBuffer *)(uintptr_t)buffer_handle;
    if (buffer == NULL) return YJ_COMPACT_CLOSED;
    if ((buffer->size != 0u && output == NULL) || output_capacity < buffer->size) {
        return YJ_COMPACT_BOUNDS_ERROR;
    }
    if (buffer->size != 0u) memcpy(output, buffer->data, (size_t)buffer->size);
    return YJ_COMPACT_OK;
}

void YJ_Compact_FreeOwnedBuffer(uint64_t buffer_handle) {
    YjBuffer *buffer = (YjBuffer *)(uintptr_t)buffer_handle;
    if (buffer == NULL) return;
    free(buffer->data);
    free(buffer);
}

int32_t YJ_Compact_Stats(uint64_t handle, uint64_t *stats, uint64_t capacity) {
    YjDocument *document = yj_from_handle(handle);
    if (document == NULL) return YJ_COMPACT_CLOSED;
    if (stats == NULL || capacity < 12u) return YJ_COMPACT_BOUNDS_ERROR;
    uint64_t values[12] = {
        document->source_owned ? document->source_length : 0u,
        document->persistent_used + document->arena.used,
        document->persistent_committed + document->arena.committed,
        document->arena.used,
        document->arena.committed,
        document->scratch_current,
        document->scratch_peak,
        document->duplicate_scratch_peak,
        document->node_count,
        document->object_count,
        document->array_count,
        document->string_count
    };
    memcpy(stats, values, sizeof(values));
    return YJ_COMPACT_OK;
}

static uint64_t yj_duplicate_percentile(YjDocument *document, uint64_t numerator,
                                        uint64_t denominator) {
    uint64_t total = 0;
    for (uint32_t i = 0; i < 32u; i++) total += document->duplicate_probe_histogram[i];
    if (total == 0) return 0;
    uint64_t target = (total * numerator + denominator - 1u) / denominator;
    uint64_t seen = 0;
    for (uint32_t i = 0; i < 32u; i++) {
        seen += document->duplicate_probe_histogram[i];
        if (seen >= target) return i == 31u ? document->duplicate_max_probe : i + 1u;
    }
    return document->duplicate_max_probe;
}

int32_t YJ_Compact_DuplicateStats(uint64_t handle, uint64_t *stats,
                                 uint64_t capacity) {
    YjDocument *document = yj_from_handle(handle);
    if (document == NULL) return YJ_COMPACT_CLOSED;
    if (stats == NULL || capacity < 16u) return YJ_COMPACT_BOUNDS_ERROR;
    stats[0] = document->duplicate_lookups;
    stats[1] = document->duplicate_inserts;
    stats[2] = document->duplicate_probes;
    stats[3] = document->duplicate_exact_equalities;
    stats[4] = document->duplicate_max_probe;
    stats[5] = document->duplicate_grow_count;
    stats[6] = document->duplicate_rehash_entries;
    stats[7] = document->duplicate_final_capacity;
    stats[8] = document->duplicate_largest_capacity;
    stats[9] = yj_duplicate_percentile(document, 1u, 2u);
    stats[10] = yj_duplicate_percentile(document, 95u, 100u);
    stats[11] = yj_duplicate_percentile(document, 99u, 100u);
    stats[12] = document->duplicate_final_size;
    stats[13] = document->duplicate_final_capacity == 0 ? 0
        : (uint64_t)document->duplicate_final_size * UINT64_C(1000000) /
          document->duplicate_final_capacity;
    stats[14] = document->duplicate_presized;
    stats[15] = 0;
    return YJ_COMPACT_OK;
}

uint64_t YJ_Compact_Noop(uint64_t value) { return value + 1u; }

int32_t YJ_Compact_ScalarProbe(uint64_t value, uint64_t *out_value) {
    if (out_value == NULL) return YJ_COMPACT_PARSE_ERROR;
    *out_value = value ^ UINT64_C(0x9e3779b97f4a7c15);
    return YJ_COMPACT_OK;
}

int32_t YJ_Compact_CopyProbe(const uint8_t *input, uint64_t length,
                            uint64_t iterations, uint64_t *out_checksum) {
    if ((input == NULL && length != 0u) || out_checksum == NULL) return YJ_COMPACT_PARSE_ERROR;
    if (length > (uint64_t)SIZE_MAX) return YJ_COMPACT_DOCUMENT_TOO_LARGE;
    uint64_t checksum = 0u;
    for (uint64_t i = 0u; i < iterations; i++) {
        uint8_t *copy = length == 0u ? NULL : (uint8_t *)malloc((size_t)length);
        if (length != 0u && copy == NULL) return YJ_COMPACT_OUT_OF_MEMORY;
        if (length != 0u) {
            memcpy(copy, input, (size_t)length);
            checksum ^= copy[(i * UINT64_C(1315423911)) % length];
        }
        free(copy);
    }
    *out_checksum = checksum;
    return YJ_COMPACT_OK;
}
