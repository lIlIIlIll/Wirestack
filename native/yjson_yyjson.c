#include "yjson_yyjson.h"

#include "yjson_compact.h"
#include "vendor/yyjson/yyjson.h"

#include <limits.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#if defined(__linux__)
#include <sys/random.h>
#endif

#if UINTPTR_MAX > UINT64_MAX
#error "FJ yyjson opaque handles require uintptr_t to fit in uint64_t"
#endif

typedef union {
    struct { size_t size; } meta;
    max_align_t alignment;
} FyAllocHeader;

typedef struct {
    uint64_t current;
    uint64_t peak;
    uint64_t total;
} FyAllocStats;

typedef struct {
    uint32_t offset;
    uint32_t length;
} FyRef;

typedef struct {
    uint64_t payload;
    uint32_t aux;
    uint8_t kind;
    uint8_t reserved[3];
} FyNode;

typedef struct {
    FyRef key;
    uint32_t value;
    uint32_t reserved;
} FyObjectEntry;

typedef struct {
    FyNode *nodes;
    uint32_t node_count;
    uint32_t node_capacity;
    uint32_t *array_entries;
    uint32_t array_count;
    uint32_t array_capacity;
    FyObjectEntry *object_entries;
    uint32_t object_count;
    uint32_t object_capacity;
    uint8_t *strings;
    uint32_t string_size;
    uint32_t string_capacity;
    uint64_t persistent_used;
    uint64_t persistent_committed;
    uint32_t root;
} FyFlatDocument;

typedef struct FyDuplicateSet FyDuplicateSet;

typedef struct {
    yyjson_doc *yy_doc;
    yyjson_val *root;
    FyFlatDocument *flat;
    FyAllocStats allocator;
    uint64_t validation_scratch_peak;
    uint64_t validation_probes;
    uint64_t validation_max_probe;
    uint64_t validation_probe_histogram[32];
    uint64_t validation_hashes;
    uint64_t validation_fingerprint_matches;
    uint64_t validation_memcmp_calls;
    uint64_t validation_memcmp_bytes;
    uint64_t validation_small_linear_objects;
    uint64_t validation_hashed_objects;
    uint64_t validation_walks;
    uint64_t literal_entries;
    uint64_t literal_bytes;
    uint64_t source_replay_bytes;
    uint64_t source_copy_bytes;
    uint64_t number_safe_ints;
    uint64_t number_raw_required;
    uint64_t root_index_bytes;
    uint64_t root_index_builds;
    uint64_t root_index_probes;
    uint64_t root_index_max_probe;
    uint64_t node_count;
    uint64_t object_fields;
    uint64_t array_entries;
    uint64_t string_count;
    uint64_t fallback_custom_handle;
    uint8_t *literal_source;
    uint64_t literal_source_size;
    uint64_t hash_seed;
    FyDuplicateSet *root_index;
    uint32_t fallback_custom_root;
    uint32_t mode;
    uint32_t flags;
} FyDocument;

typedef struct {
    uint8_t *data;
    uint64_t size;
} FyOwnedBuffer;

typedef struct {
    uint8_t *data;
    uint64_t size;
    uint64_t capacity;
    int failed;
} FyBuffer;

struct FyDuplicateSet {
    uint64_t *slots;
    uint32_t capacity;
    uint32_t size;
};

static void *fy_tracked_malloc(void *context, size_t size) {
    FyAllocStats *stats = (FyAllocStats *)context;
    if (size > SIZE_MAX - sizeof(FyAllocHeader)) return NULL;
    FyAllocHeader *header = (FyAllocHeader *)malloc(sizeof(FyAllocHeader) + size);
    if (header == NULL) return NULL;
    header->meta.size = size;
    stats->current += size;
    stats->total += size;
    if (stats->current > stats->peak) stats->peak = stats->current;
    return header + 1;
}

static void *fy_tracked_realloc(void *context, void *pointer,
                                size_t old_size, size_t size) {
    (void)old_size;
    if (pointer == NULL) return fy_tracked_malloc(context, size);
    FyAllocStats *stats = (FyAllocStats *)context;
    FyAllocHeader *old_header = ((FyAllocHeader *)pointer) - 1;
    size_t actual_old = old_header->meta.size;
    if (size > SIZE_MAX - sizeof(FyAllocHeader)) return NULL;
    FyAllocHeader *header = (FyAllocHeader *)realloc(old_header,
        sizeof(FyAllocHeader) + size);
    if (header == NULL) return NULL;
    header->meta.size = size;
    stats->current = stats->current - actual_old + size;
    if (size > actual_old) stats->total += size - actual_old;
    if (stats->current > stats->peak) stats->peak = stats->current;
    return header + 1;
}

static void fy_tracked_free(void *context, void *pointer) {
    if (pointer == NULL) return;
    FyAllocStats *stats = (FyAllocStats *)context;
    FyAllocHeader *header = ((FyAllocHeader *)pointer) - 1;
    stats->current -= header->meta.size;
    free(header);
}

static uint64_t fy_wymix(uint64_t a, uint64_t b) {
#if defined(__SIZEOF_INT128__)
    __uint128_t product = (__uint128_t)a * (__uint128_t)b;
    return (uint64_t)product ^ (uint64_t)(product >> 64);
#else
    uint64_t ah = a >> 32, al = (uint32_t)a;
    uint64_t bh = b >> 32, bl = (uint32_t)b;
    uint64_t high = ah * bh, mid0 = ah * bl, mid1 = al * bh, low = al * bl;
    uint64_t first = low + (mid0 << 32), carry = first < low;
    uint64_t second = first + (mid1 << 32);
    carry += second < first;
    return second ^ (high + (mid0 >> 32) + (mid1 >> 32) + carry);
#endif
}

static uint64_t fy_read64(const uint8_t *data) {
    uint64_t value;
    memcpy(&value, data, sizeof(value));
    return value;
}

static uint64_t fy_hash_seeded(const uint8_t *data, uint32_t length,
                               uint64_t document_seed) {
    const uint64_t s0 = UINT64_C(0xa0761d6478bd642f);
    const uint64_t s1 = UINT64_C(0xe7037ed1a0b428db);
    uint64_t seed = fy_wymix(s0 ^ document_seed, s1) ^ length;
    uint32_t at = 0;
    while (length - at >= 16u) {
        seed = fy_wymix(fy_read64(data + at) ^ s1,
                        fy_read64(data + at + 8u) ^ seed);
        at += 16u;
    }
    uint64_t a = 0, b = 0;
    uint32_t remaining = length - at;
    if (remaining >= 8u) {
        a = fy_read64(data + at);
        memcpy(&b, data + at + remaining - 8u, 8u);
    } else if (remaining != 0) {
        for (uint32_t i = 0; i < remaining; i++) a = (a << 8) | data[at + i];
        b = remaining;
    }
    return fy_wymix(a ^ s0 ^ length, b ^ seed ^ s1);
}

static uint64_t fy_hash(const uint8_t *data, uint32_t length) {
    return fy_hash_seeded(data, length, 0);
}

static uint64_t fy_random_seed(void) {
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
    /* Entropy failure is rare; keep parsing correct while reporting a
     * process-specific fallback rather than silently using the old constant. */
    return fy_wymix((uint64_t)(uintptr_t)&stream,
                    UINT64_C(0xd6e8feb86659fd93));
}

static uint32_t fy_fingerprint(uint64_t hash) {
#if defined(YJ_WEAK_FINGERPRINT)
    (void)hash;
    return 1u;
#else
    uint32_t value = (uint32_t)(hash ^ (hash >> 32));
    return value == 0 ? 1u : value;
#endif
}

static int fy_raw_int64(const char *text, size_t length, int64_t *out) {
    size_t at = 0;
    int negative = 0;
    uint64_t magnitude = 0;
    if (length == 0) return 0;
    if (text[at] == '-') { negative = 1; at++; }
    if (at == length) return 0;
    for (; at < length; at++) {
        uint8_t c = (uint8_t)text[at];
        if (c < '0' || c > '9') return 0;
        uint32_t digit = c - '0';
        if (magnitude > (UINT64_MAX - digit) / 10u) return 0;
        magnitude = magnitude * 10u + digit;
    }
    uint64_t limit = negative ? (UINT64_C(1) << 63) : (uint64_t)INT64_MAX;
    if (magnitude > limit) return 0;
    if (negative) *out = magnitude == (UINT64_C(1) << 63)
        ? INT64_MIN : -(int64_t)magnitude;
    else *out = (int64_t)magnitude;
    return 1;
}

static int fy_duplicate_init(FyDuplicateSet *set, size_t count,
                             uint64_t *scratch_peak) {
    if (count <= 8) return 1;
    size_t capacity = 16;
    while (capacity < count * 2u) {
        if (capacity > UINT32_MAX / 2u) return 0;
        capacity *= 2u;
    }
    set->slots = (uint64_t *)calloc(capacity, sizeof(uint64_t));
    if (set->slots == NULL) {
        memset(set, 0, sizeof(*set));
        return 0;
    }
    set->capacity = (uint32_t)capacity;
    uint64_t bytes = capacity * sizeof(uint64_t);
    if (bytes > *scratch_peak) *scratch_peak = bytes;
    return 1;
}

static void fy_duplicate_free(FyDuplicateSet *set) {
    if (set == NULL) return;
    free(set->slots);
    memset(set, 0, sizeof(*set));
}

static void fy_record_probe(FyDocument *document, uint64_t probes, int lookup) {
    if (lookup) {
        document->root_index_probes += probes;
        if (probes > document->root_index_max_probe)
            document->root_index_max_probe = probes;
        return;
    }
    document->validation_probes += probes;
    if (probes > document->validation_max_probe)
        document->validation_max_probe = probes;
    uint32_t bucket = probes >= 32u ? 31u : (uint32_t)probes - 1u;
    document->validation_probe_histogram[bucket]++;
}

static int fy_duplicate_find_or_insert(FyDocument *document,
                                       FyDuplicateSet *set,
                                       yyjson_val *key,
                                       int *duplicate) {
    const uint8_t *text = (const uint8_t *)yyjson_get_str(key);
    uint32_t length = (uint32_t)yyjson_get_len(key);
    uint64_t hash = fy_hash_seeded(text, length, document->hash_seed);
    uint32_t fingerprint = fy_fingerprint(hash);
    uint32_t mask = set->capacity - 1u;
    uint32_t slot = (uint32_t)hash & mask;
    uint64_t probes = 0;
    uintptr_t key_address = (uintptr_t)key;
    uintptr_t base_address = (uintptr_t)document->root;
    if (key_address < base_address || key_address - base_address > UINT32_MAX)
        return 0;
    uint32_t key_offset = (uint32_t)(key_address - base_address);
    uint64_t packed = ((uint64_t)fingerprint << 32) | key_offset;
    document->validation_hashes++;
    while (1) {
        probes++;
        uint64_t prior_slot = set->slots[slot];
        if (prior_slot == 0) {
            set->slots[slot] = packed;
            set->size++;
            fy_record_probe(document, probes, 0);
            return 1;
        }
        if ((uint32_t)(prior_slot >> 32) == fingerprint) {
            yyjson_val *prior = (yyjson_val *)(void *)(base_address +
                (uint32_t)prior_slot);
            document->validation_fingerprint_matches++;
            if (yyjson_get_len(prior) == length) {
                document->validation_memcmp_calls++;
                document->validation_memcmp_bytes += length;
                if (length == 0 || memcmp(yyjson_get_str(prior), text, length) == 0) {
                    *duplicate = 1;
                    fy_record_probe(document, probes, 0);
                    return 1;
                }
            }
        }
        slot = (slot + 1u) & mask;
    }
}

static int fy_validate_value(FyDocument *document, yyjson_val *value,
                             int64_t depth, int64_t max_depth,
                             int *duplicate, int *too_deep) {
    if (depth == 0) document->validation_walks++;
    if (depth >= max_depth) { *too_deep = 1; return 1; }
    document->node_count++;
    if (yyjson_is_raw(value) &&
        (document->flags & YJ_YYJSON_PRESERVE_NUMBERS) == 0 &&
        yyjson_get_len(value) == 2u && yyjson_get_raw(value)[0] == '-' &&
        yyjson_get_raw(value)[1] == '0') yyjson_set_sint(value, 0);
    if (yyjson_is_str(value) || yyjson_is_raw(value)) document->string_count++;
    if (yyjson_is_arr(value)) {
        size_t index, count;
        yyjson_val *child;
        count = yyjson_arr_size(value);
        document->array_entries += count;
        yyjson_arr_foreach(value, index, count, child) {
            if (!fy_validate_value(document, child, depth + 1, max_depth,
                                   duplicate, too_deep)) return 0;
        }
        return 1;
    }
    if (!yyjson_is_obj(value)) return 1;
    size_t count = yyjson_obj_size(value);
    document->object_fields += count;
    FyDuplicateSet set = {0};
    if (!fy_duplicate_init(&set, count, &document->validation_scratch_peak)) return 0;
    if (set.capacity == 0) document->validation_small_linear_objects++;
    else document->validation_hashed_objects++;
    yyjson_obj_iter iter = yyjson_obj_iter_with(value);
    yyjson_val *key;
    uint32_t ordinal = 0;
    while ((key = yyjson_obj_iter_next(&iter)) != NULL) {
        yyjson_val *child = yyjson_obj_iter_get_val(key);
        const uint8_t *text = (const uint8_t *)yyjson_get_str(key);
        uint32_t length = (uint32_t)yyjson_get_len(key);
        if (set.capacity == 0) {
            yyjson_obj_iter prior = yyjson_obj_iter_with(value);
            yyjson_val *prior_key;
            uint32_t prior_ordinal = 0;
            while (prior_ordinal < ordinal &&
                   (prior_key = yyjson_obj_iter_next(&prior)) != NULL) {
                if (yyjson_get_len(prior_key) == length &&
                    (document->validation_memcmp_calls++,
                     document->validation_memcmp_bytes += length,
                     length == 0 || memcmp(yyjson_get_str(prior_key), text, length) == 0)) {
                    *duplicate = 1;
                    break;
                }
                prior_ordinal++;
            }
        } else {
            if (!fy_duplicate_find_or_insert(document, &set, key, duplicate)) {
                fy_duplicate_free(&set);
                return 0;
            }
        }
        if (*duplicate) break;
        ordinal++;
        if (!fy_validate_value(document, child, depth + 1, max_depth,
                               duplicate, too_deep)) {
            fy_duplicate_free(&set);
            return 0;
        }
        if (*too_deep) break;
    }
    if (!*duplicate && !*too_deep && value == document->root &&
        (document->flags & YJ_YYJSON_RETAIN_ROOT_INDEX) != 0 &&
        set.capacity != 0 && count >= 256u) {
        document->root_index = (FyDuplicateSet *)malloc(sizeof(FyDuplicateSet));
        if (document->root_index == NULL) { fy_duplicate_free(&set); return 0; }
        *document->root_index = set;
        document->root_index_bytes = (uint64_t)set.capacity * sizeof(uint64_t);
        document->root_index_builds++;
        memset(&set, 0, sizeof(set));
    }
    fy_duplicate_free(&set);
    return 1;
}

static int fy_validate_dense_int_array(FyDocument *document, yyjson_val *value,
                                       int64_t depth, int64_t max_depth,
                                       int *too_deep) {
    if (depth >= max_depth) { *too_deep = 1; return 1; }
    document->node_count++;
    if (yyjson_is_sint(value)) return 1;
    if (yyjson_is_uint(value)) return yyjson_get_uint(value) <= (uint64_t)INT64_MAX;
    if (!yyjson_is_arr(value)) return 0;
    size_t index, count = yyjson_arr_size(value);
    yyjson_val *child;
    document->array_entries += count;
    yyjson_arr_foreach(value, index, count, child) {
        if (!fy_validate_dense_int_array(document, child, depth + 1,
                                         max_depth, too_deep)) return 0;
        if (*too_deep) return 1;
    }
    return 1;
}

typedef struct {
    const uint8_t *input;
    size_t length;
    size_t at;
    FyDocument *document;
    int preserve_all;
    int validate;
    int64_t max_depth;
    int duplicate;
    int too_deep;
} FySourceReplay;

static int fy_is_space(uint8_t c) {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r';
}

static void fy_replay_space(FySourceReplay *replay) {
    while (replay->at < replay->length && fy_is_space(replay->input[replay->at]))
        replay->at++;
}

static int fy_replay_string(FySourceReplay *replay) {
    if (replay->at >= replay->length || replay->input[replay->at] != '"') return 0;
    replay->at++;
    while (replay->at < replay->length) {
        uint8_t c = replay->input[replay->at++];
        if (c == '"') return 1;
        if (c == '\\') {
            if (replay->at >= replay->length) return 0;
            replay->at++;
        }
    }
    return 0;
}

static size_t fy_number_end(const uint8_t *input, size_t length, size_t at) {
    while (at < length) {
        uint8_t c = input[at];
        if (fy_is_space(c) || c == ',' || c == ']' || c == '}') break;
        at++;
    }
    return at;
}

static int fy_ensure_literal_source(FySourceReplay *replay) {
    if (replay->document->literal_source != NULL) return 1;
    if (replay->length == SIZE_MAX) return 0;
    uint8_t *copy = (uint8_t *)malloc(replay->length + 1u);
    if (copy == NULL) return 0;
    memcpy(copy, replay->input, replay->length);
    copy[replay->length] = 0;
    replay->document->literal_source = copy;
    replay->document->literal_source_size = replay->length + 1u;
    replay->document->source_copy_bytes = replay->length + 1u;
    return 1;
}

static int fy_replay_value(FySourceReplay *replay, yyjson_val *value,
                           int64_t depth) {
    fy_replay_space(replay);
    if (replay->at >= replay->length) return 0;
    if (replay->validate && depth >= replay->max_depth) {
        replay->too_deep = 1;
        return 1;
    }
    if (replay->validate) replay->document->node_count++;
    uint8_t c = replay->input[replay->at];
    if (c == '{') {
        if (!yyjson_is_obj(value)) return 0;
        size_t count = yyjson_obj_size(value);
        if (replay->validate) replay->document->object_fields += count;
        FyDuplicateSet set = {0};
        if (replay->validate) {
            if (!fy_duplicate_init(&set, count,
                                   &replay->document->validation_scratch_peak)) return 0;
            if (set.capacity == 0) replay->document->validation_small_linear_objects++;
            else replay->document->validation_hashed_objects++;
        }
        replay->at++;
        fy_replay_space(replay);
        yyjson_obj_iter iter = yyjson_obj_iter_with(value);
        yyjson_val *key;
        size_t ordinal = 0;
        while ((key = yyjson_obj_iter_next(&iter)) != NULL) {
            if (ordinal != 0) {
                if (replay->at >= replay->length || replay->input[replay->at] != ',') return 0;
                replay->at++; fy_replay_space(replay);
            }
            if (!fy_replay_string(replay)) { fy_duplicate_free(&set); return 0; }
            const uint8_t *text = (const uint8_t *)yyjson_get_str(key);
            uint32_t key_length = (uint32_t)yyjson_get_len(key);
            if (!replay->validate) {
                /* Number replay only; duplicate/depth work is in the separate pass. */
            } else if (set.capacity == 0) {
                yyjson_obj_iter prior = yyjson_obj_iter_with(value);
                yyjson_val *prior_key;
                size_t prior_ordinal = 0;
                while (prior_ordinal < ordinal &&
                       (prior_key = yyjson_obj_iter_next(&prior)) != NULL) {
                    if (yyjson_get_len(prior_key) == key_length &&
                        (replay->document->validation_memcmp_calls++,
                         replay->document->validation_memcmp_bytes += key_length,
                         key_length == 0 || memcmp(yyjson_get_str(prior_key), text,
                                                   key_length) == 0)) {
                        replay->duplicate = 1;
                        break;
                    }
                    prior_ordinal++;
                }
            } else if (!fy_duplicate_find_or_insert(replay->document, &set,
                                                     key, &replay->duplicate)) {
                fy_duplicate_free(&set);
                return 0;
            }
            if (replay->duplicate) { fy_duplicate_free(&set); return 1; }
            fy_replay_space(replay);
            if (replay->at >= replay->length || replay->input[replay->at] != ':') {
                fy_duplicate_free(&set); return 0;
            }
            replay->at++;
            if (!fy_replay_value(replay, yyjson_obj_iter_get_val(key), depth + 1)) {
                fy_duplicate_free(&set); return 0;
            }
            if (replay->too_deep) { fy_duplicate_free(&set); return 1; }
            fy_replay_space(replay);
            ordinal++;
        }
        if (ordinal != count || replay->at >= replay->length ||
            replay->input[replay->at] != '}') { fy_duplicate_free(&set); return 0; }
        replay->at++;
        if (replay->validate && value == replay->document->root &&
            (replay->document->flags & YJ_YYJSON_RETAIN_ROOT_INDEX) != 0 &&
            set.capacity != 0 && count >= 256u) {
            replay->document->root_index =
                (FyDuplicateSet *)malloc(sizeof(FyDuplicateSet));
            if (replay->document->root_index == NULL) {
                fy_duplicate_free(&set); return 0;
            }
            *replay->document->root_index = set;
            replay->document->root_index_bytes =
                (uint64_t)set.capacity * sizeof(uint64_t);
            replay->document->root_index_builds++;
            memset(&set, 0, sizeof(set));
        }
        fy_duplicate_free(&set);
        return 1;
    }
    if (c == '[') {
        if (!yyjson_is_arr(value)) return 0;
        if (replay->validate)
            replay->document->array_entries += yyjson_arr_size(value);
        replay->at++;
        fy_replay_space(replay);
        yyjson_arr_iter iter = yyjson_arr_iter_with(value);
        yyjson_val *child;
        size_t ordinal = 0, count = yyjson_arr_size(value);
        while ((child = yyjson_arr_iter_next(&iter)) != NULL) {
            if (ordinal != 0) {
                if (replay->at >= replay->length || replay->input[replay->at] != ',') return 0;
                replay->at++; fy_replay_space(replay);
            }
            if (!fy_replay_value(replay, child, depth + 1)) return 0;
            if (replay->too_deep) return 1;
            fy_replay_space(replay);
            ordinal++;
        }
        if (ordinal != count || replay->at >= replay->length ||
            replay->input[replay->at] != ']') return 0;
        replay->at++;
        return 1;
    }
    if (c == '"') {
        if (replay->validate) replay->document->string_count++;
        return yyjson_is_str(value) && fy_replay_string(replay);
    }
    if (c == 't') { replay->at += 4u; return yyjson_is_true(value); }
    if (c == 'f') { replay->at += 5u; return yyjson_is_false(value); }
    if (c == 'n') { replay->at += 4u; return yyjson_is_null(value); }
    if (c == '-' || (c >= '0' && c <= '9')) {
        size_t start = replay->at;
        size_t end = fy_number_end(replay->input, replay->length, start);
        int64_t integer = 0;
        int safe_int = fy_raw_int64((const char *)replay->input + start,
                                    end - start, &integer);
        if (safe_int) replay->document->number_safe_ints++;
        else replay->document->number_raw_required++;
        if (replay->preserve_all || !safe_int) {
            if (!fy_ensure_literal_source(replay)) return 0;
            yyjson_set_raw(value, (const char *)replay->document->literal_source + start,
                           end - start);
            replay->document->literal_entries++;
            replay->document->literal_bytes += end - start;
        }
        replay->at = end;
        return 1;
    }
    return 0;
}

static int fy_apply_number_semantics(FyDocument *document,
                                     const uint8_t *input, size_t length,
                                     int preserve_all, int64_t max_depth,
                                     int validate, int *duplicate,
                                     int *too_deep) {
    FySourceReplay replay = {input, length, 0, document, preserve_all,
                             validate, max_depth, 0, 0};
    if (validate) document->validation_walks++;
    document->source_replay_bytes = length;
    if (!fy_replay_value(&replay, document->root, 0)) return 0;
    fy_replay_space(&replay);
    *duplicate = replay.duplicate;
    *too_deep = replay.too_deep;
    return (replay.duplicate || replay.too_deep) || replay.at == length;
}

static int fy_numeric_array_dispatch_candidate(FyDocument *document,
                                               const uint8_t *input,
                                               size_t length) {
    const size_t limit = length < 65536u ? length : 65536u;
    size_t at = 0;
    int in_string = 0, escaped = 0;
    uint32_t numbers = 0;
    while (at < limit && fy_is_space(input[at])) at++;
    if (at >= limit || input[at] != '[') return 0;
    while (at < limit) {
        uint8_t c = input[at];
        if (in_string) {
            if (escaped) escaped = 0;
            else if (c == '\\') escaped = 1;
            else if (c == '"') in_string = 0;
            at++;
            continue;
        }
        if (c == '"' || c == '{') return 0;
        if (c == '-' || (c >= '0' && c <= '9')) {
            size_t end = fy_number_end(input, limit, at);
            int64_t integer = 0;
            if (fy_raw_int64((const char *)input + at, end - at, &integer))
                document->number_safe_ints++;
            else document->number_raw_required++;
            numbers++;
            at = end;
            continue;
        }
        at++;
    }
    document->source_replay_bytes = limit;
    return numbers >= 128u;
}

static int fy_reserve(void **items, uint32_t *capacity, uint32_t required,
                      size_t width, FyFlatDocument *document) {
    if (required <= *capacity) return 1;
    uint32_t next = *capacity == 0 ? 16u : *capacity;
    while (next < required) {
        if (next > UINT32_MAX / 2u) { next = required; break; }
        next *= 2u;
    }
    if ((uint64_t)next * width > SIZE_MAX) return 0;
    void *replacement = realloc(*items, (size_t)next * width);
    if (replacement == NULL) return 0;
    document->persistent_committed += (uint64_t)(next - *capacity) * width;
    *items = replacement;
    *capacity = next;
    return 1;
}

static int fy_flat_add_string(FyFlatDocument *document,
                              const uint8_t *text, uint32_t length,
                              FyRef *out) {
    if (UINT32_MAX - document->string_size < length) return 0;
    uint32_t required = document->string_size + length;
    if (!fy_reserve((void **)&document->strings, &document->string_capacity,
                    required, 1u, document)) return 0;
    out->offset = document->string_size;
    out->length = length;
    if (length != 0) memcpy(document->strings + document->string_size, text, length);
    document->string_size = required;
    document->persistent_used += length;
    return 1;
}

static int fy_flat_add_node(FyFlatDocument *document, uint8_t kind,
                            uint64_t payload, uint32_t aux,
                            uint32_t *out) {
    if (!fy_reserve((void **)&document->nodes, &document->node_capacity,
                    document->node_count + 1u, sizeof(FyNode), document)) return 0;
    uint32_t index = document->node_count++;
    document->nodes[index].payload = payload;
    document->nodes[index].aux = aux;
    document->nodes[index].kind = kind;
    memset(document->nodes[index].reserved, 0, sizeof(document->nodes[index].reserved));
    document->persistent_used += sizeof(FyNode);
    *out = index;
    return 1;
}

static int fy_flat_value(FyFlatDocument *document, yyjson_val *value,
                         uint32_t *out_node) {
    if (yyjson_is_null(value)) return fy_flat_add_node(document, YJ_COMPACT_NULL, 0, 0, out_node);
    if (yyjson_is_bool(value)) return fy_flat_add_node(document, YJ_COMPACT_BOOL,
        yyjson_get_bool(value) ? 1u : 0u, 0, out_node);
    if (yyjson_is_sint(value) || yyjson_is_uint(value)) {
        int64_t integer;
        if (yyjson_is_sint(value)) integer = yyjson_get_sint(value);
        else {
            uint64_t number = yyjson_get_uint(value);
            if (number > (uint64_t)INT64_MAX) return 0;
            integer = (int64_t)number;
        }
        uint64_t payload;
        memcpy(&payload, &integer, sizeof(payload));
        return fy_flat_add_node(document, YJ_COMPACT_INT, payload, 0, out_node);
    }
    if (yyjson_is_raw(value)) {
        const char *raw = yyjson_get_raw(value);
        uint32_t length = (uint32_t)yyjson_get_len(value);
        int64_t integer;
        if (fy_raw_int64(raw, length, &integer)) {
            uint64_t payload;
            memcpy(&payload, &integer, sizeof(payload));
            return fy_flat_add_node(document, YJ_COMPACT_INT, payload, 0, out_node);
        }
        FyRef ref;
        if (!fy_flat_add_string(document, (const uint8_t *)raw, length, &ref)) return 0;
        uint64_t payload = ((uint64_t)ref.offset << 32) | ref.length;
        return fy_flat_add_node(document, YJ_COMPACT_NUMBER, payload, 0, out_node);
    }
    if (yyjson_is_str(value)) {
        FyRef ref;
        if (!fy_flat_add_string(document, (const uint8_t *)yyjson_get_str(value),
                                (uint32_t)yyjson_get_len(value), &ref)) return 0;
        uint64_t payload = ((uint64_t)ref.offset << 32) | ref.length;
        return fy_flat_add_node(document, YJ_COMPACT_STRING, payload, 0, out_node);
    }
    if (yyjson_is_arr(value)) {
        uint32_t count = (uint32_t)yyjson_arr_size(value);
        uint32_t *local = count == 0 ? NULL : (uint32_t *)malloc((size_t)count * sizeof(uint32_t));
        if (count != 0 && local == NULL) return 0;
        yyjson_arr_iter iter = yyjson_arr_iter_with(value);
        yyjson_val *child;
        uint32_t index = 0;
        while ((child = yyjson_arr_iter_next(&iter)) != NULL) {
            if (!fy_flat_value(document, child, &local[index++])) { free(local); return 0; }
        }
        uint32_t start = document->array_count;
        if (!fy_reserve((void **)&document->array_entries, &document->array_capacity,
                        start + count, sizeof(uint32_t), document)) { free(local); return 0; }
        if (count != 0) memcpy(document->array_entries + start, local,
                               (size_t)count * sizeof(uint32_t));
        free(local);
        document->array_count += count;
        document->persistent_used += (uint64_t)count * sizeof(uint32_t);
        return fy_flat_add_node(document, YJ_COMPACT_ARRAY, start, count, out_node);
    }
    if (yyjson_is_obj(value)) {
        uint32_t count = (uint32_t)yyjson_obj_size(value);
        FyObjectEntry *local = count == 0 ? NULL
            : (FyObjectEntry *)malloc((size_t)count * sizeof(FyObjectEntry));
        if (count != 0 && local == NULL) return 0;
        yyjson_obj_iter iter = yyjson_obj_iter_with(value);
        yyjson_val *key;
        uint32_t index = 0;
        while ((key = yyjson_obj_iter_next(&iter)) != NULL) {
            if (!fy_flat_add_string(document, (const uint8_t *)yyjson_get_str(key),
                                    (uint32_t)yyjson_get_len(key), &local[index].key) ||
                !fy_flat_value(document, yyjson_obj_iter_get_val(key), &local[index].value)) {
                free(local); return 0;
            }
            local[index].reserved = 0;
            index++;
        }
        uint32_t start = document->object_count;
        if (!fy_reserve((void **)&document->object_entries, &document->object_capacity,
                        start + count, sizeof(FyObjectEntry), document)) { free(local); return 0; }
        if (count != 0) memcpy(document->object_entries + start, local,
                               (size_t)count * sizeof(FyObjectEntry));
        free(local);
        document->object_count += count;
        document->persistent_used += (uint64_t)count * sizeof(FyObjectEntry);
        return fy_flat_add_node(document, YJ_COMPACT_OBJECT, start, count, out_node);
    }
    return 0;
}

static void fy_flat_free(FyFlatDocument *document) {
    if (document == NULL) return;
    free(document->nodes);
    free(document->array_entries);
    free(document->object_entries);
    free(document->strings);
    free(document);
}

static int32_t fy_map_error(uint32_t yy_code) {
    if (yy_code == YYJSON_READ_ERROR_MEMORY_ALLOCATION) return YJ_COMPACT_OUT_OF_MEMORY;
    if (yy_code == YYJSON_READ_ERROR_INVALID_STRING) return YJ_COMPACT_INVALID_UTF8;
    return YJ_COMPACT_PARSE_ERROR;
}

static void fy_free_document(FyDocument *document) {
    if (document == NULL) return;
    if (document->yy_doc != NULL) yyjson_doc_free(document->yy_doc);
    if (document->fallback_custom_handle != 0)
        YJ_Compact_Free(document->fallback_custom_handle);
    if (document->root_index != NULL) {
        fy_duplicate_free(document->root_index);
        free(document->root_index);
    }
    free(document->literal_source);
    fy_flat_free(document->flat);
    free(document);
}

int32_t YJ_Yyjson_Parse(const uint8_t *input, int64_t length,
                       uint32_t flags, int64_t max_depth, uint32_t mode,
                       uint64_t *out_handle, uint32_t *out_error_code,
                       int64_t *out_error_offset) {
    if (out_handle == NULL || out_error_code == NULL || out_error_offset == NULL)
        return YJ_COMPACT_PARSE_ERROR;
    *out_handle = 0; *out_error_code = YJ_COMPACT_OK; *out_error_offset = -1;
    if (input == NULL || length <= 0 || max_depth <= 0 ||
        (mode != YJ_YYJSON_DIRECT && mode != YJ_YYJSON_TRANSCODE)) {
        *out_error_code = YJ_COMPACT_PARSE_ERROR; *out_error_offset = 0;
        return YJ_COMPACT_PARSE_ERROR;
    }
    FyDocument *document = (FyDocument *)calloc(1, sizeof(FyDocument));
    if (document == NULL) { *out_error_code = YJ_COMPACT_OUT_OF_MEMORY; return YJ_COMPACT_OUT_OF_MEMORY; }
    document->mode = mode;
    document->flags = flags;
    document->hash_seed = fy_random_seed();
    int preserve_all = (flags & YJ_YYJSON_PRESERVE_NUMBERS) != 0;
    int dispatch_numbers = (flags & YJ_YYJSON_NUMBER_DISPATCH_CUSTOM) != 0;
    int dispatch_dense_numeric = dispatch_numbers && !preserve_all &&
        fy_numeric_array_dispatch_candidate(document, input, (size_t)length);
    if (dispatch_dense_numeric && document->number_raw_required != 0) {
        uint64_t custom_handle = 0;
        uint32_t custom_root = 0, custom_error = 0;
        int64_t custom_offset = -1;
        uint32_t custom_flags = 0;
        if ((flags & YJ_YYJSON_REJECT_DUPLICATES) != 0)
            custom_flags |= YJ_COMPACT_REJECT_DUPLICATES;
        int32_t status = YJ_Compact_Parse(input, length, custom_flags, max_depth,
            &custom_handle, &custom_root, &custom_error, &custom_offset);
        if (status != YJ_COMPACT_OK) {
            *out_error_code = custom_error;
            *out_error_offset = custom_offset;
            fy_free_document(document);
            return status;
        }
        document->fallback_custom_handle = custom_handle;
        document->fallback_custom_root = custom_root;
        *out_handle = (uint64_t)(uintptr_t)document;
        return YJ_COMPACT_OK;
    }
    yyjson_alc allocator = {fy_tracked_malloc, fy_tracked_realloc,
                            fy_tracked_free, &document->allocator};
    yyjson_read_err error;
    yyjson_read_flag read_flags = !dispatch_dense_numeric &&
        (flags & YJ_YYJSON_NUMBER_LEGACY_RAW) != 0
        ? YYJSON_READ_NUMBER_AS_RAW : YYJSON_READ_BIGNUM_AS_RAW;
    document->yy_doc = yyjson_read_opts((char *)(uintptr_t)input, (size_t)length,
                                        read_flags, &allocator, &error);
    if (document->yy_doc == NULL) {
        *out_error_code = (uint32_t)fy_map_error(error.code);
        *out_error_offset = (int64_t)error.pos;
        fy_free_document(document);
        return (int32_t)*out_error_code;
    }
    document->root = yyjson_doc_get_root(document->yy_doc);
    int duplicate = 0, too_deep = 0;
    if (dispatch_dense_numeric) {
        document->validation_walks++;
        if (fy_validate_dense_int_array(document, document->root, 0, max_depth,
                                        &too_deep) && !too_deep) {
            *out_handle = (uint64_t)(uintptr_t)document;
            return YJ_COMPACT_OK;
        }
        yyjson_doc_free(document->yy_doc);
        document->yy_doc = NULL;
        document->root = NULL;
        document->node_count = 0;
        document->array_entries = 0;
        uint64_t custom_handle = 0;
        uint32_t custom_root = 0, custom_error = 0;
        int64_t custom_offset = -1;
        uint32_t custom_flags = preserve_all ? YJ_COMPACT_PRESERVE_NUMBERS : 0u;
        if ((flags & YJ_YYJSON_REJECT_DUPLICATES) != 0)
            custom_flags |= YJ_COMPACT_REJECT_DUPLICATES;
        int32_t status = YJ_Compact_Parse(input, length, custom_flags, max_depth,
            &custom_handle, &custom_root, &custom_error, &custom_offset);
        if (status != YJ_COMPACT_OK) {
            *out_error_code = custom_error;
            *out_error_offset = custom_offset;
            fy_free_document(document);
            return status;
        }
        document->fallback_custom_handle = custom_handle;
        document->fallback_custom_root = custom_root;
        *out_handle = (uint64_t)(uintptr_t)document;
        return YJ_COMPACT_OK;
    }
    int separate_validation = (flags & YJ_YYJSON_NUMBER_LEGACY_RAW) != 0 ||
        (flags & YJ_YYJSON_SEPARATE_VALIDATION) != 0 || dispatch_numbers;
    if ((flags & YJ_YYJSON_NUMBER_LEGACY_RAW) == 0 && !dispatch_numbers &&
        !fy_apply_number_semantics(document, input, (size_t)length, preserve_all,
                                   max_depth, !separate_validation,
                                   &duplicate, &too_deep)) {
        *out_error_code = YJ_COMPACT_OUT_OF_MEMORY;
        fy_free_document(document);
        return YJ_COMPACT_OUT_OF_MEMORY;
    }
    if (separate_validation &&
        !fy_validate_value(document, document->root, 0, max_depth,
                           &duplicate, &too_deep)) {
        *out_error_code = YJ_COMPACT_OUT_OF_MEMORY;
        fy_free_document(document);
        return YJ_COMPACT_OUT_OF_MEMORY;
    }
    if (duplicate || too_deep) {
        uint64_t custom_handle = 0;
        uint32_t custom_root = 0, custom_error = 0;
        int64_t custom_offset = -1;
        uint32_t custom_flags = 0;
        if ((flags & YJ_YYJSON_PRESERVE_NUMBERS) != 0)
            custom_flags |= YJ_COMPACT_PRESERVE_NUMBERS;
        if ((flags & YJ_YYJSON_REJECT_DUPLICATES) != 0)
            custom_flags |= YJ_COMPACT_REJECT_DUPLICATES;
        int32_t status = YJ_Compact_Parse(input, length, custom_flags, max_depth,
            &custom_handle, &custom_root, &custom_error, &custom_offset);
        if (status != YJ_COMPACT_OK) {
            *out_error_code = custom_error;
            *out_error_offset = custom_offset;
            fy_free_document(document);
            return status;
        }
        yyjson_doc_free(document->yy_doc);
        document->yy_doc = NULL;
        document->root = NULL;
        if (document->root_index != NULL) {
            fy_duplicate_free(document->root_index);
            free(document->root_index);
            document->root_index = NULL;
            document->root_index_bytes = 0;
        }
        free(document->literal_source);
        document->literal_source = NULL;
        document->literal_source_size = 0;
        document->fallback_custom_handle = custom_handle;
        document->fallback_custom_root = custom_root;
    } else if (mode == YJ_YYJSON_TRANSCODE) {
        document->flat = (FyFlatDocument *)calloc(1, sizeof(FyFlatDocument));
        if (document->flat == NULL ||
            !fy_flat_value(document->flat, document->root, &document->flat->root)) {
            *out_error_code = YJ_COMPACT_OUT_OF_MEMORY;
            fy_free_document(document);
            return YJ_COMPACT_OUT_OF_MEMORY;
        }
        yyjson_doc_free(document->yy_doc);
        document->yy_doc = NULL;
        document->root = NULL;
    }
    *out_handle = (uint64_t)(uintptr_t)document;
    return YJ_COMPACT_OK;
}

void YJ_Yyjson_Free(uint64_t handle) {
    fy_free_document((FyDocument *)(uintptr_t)handle);
}

static uint64_t fy_direct_checksum(yyjson_val *value) {
    if (yyjson_is_null(value)) return 1;
    if (yyjson_is_bool(value)) return yyjson_get_bool(value) ? 3 : 5;
    if (yyjson_is_raw(value)) {
        const uint8_t *text = (const uint8_t *)yyjson_get_raw(value);
        uint32_t length = (uint32_t)yyjson_get_len(value);
        return fy_hash(text, length) ^ length;
    }
    if (yyjson_is_str(value)) {
        const uint8_t *text = (const uint8_t *)yyjson_get_str(value);
        uint32_t length = (uint32_t)yyjson_get_len(value);
        return fy_hash(text, length) ^ length;
    }
    uint64_t result = yyjson_get_len(value);
    if (yyjson_is_arr(value)) {
        yyjson_arr_iter iter = yyjson_arr_iter_with(value);
        yyjson_val *child;
        while ((child = yyjson_arr_iter_next(&iter)) != NULL)
            result ^= fy_direct_checksum(child);
    } else if (yyjson_is_obj(value)) {
        yyjson_obj_iter iter = yyjson_obj_iter_with(value);
        yyjson_val *key;
        while ((key = yyjson_obj_iter_next(&iter)) != NULL) {
            result ^= fy_hash((const uint8_t *)yyjson_get_str(key),
                              (uint32_t)yyjson_get_len(key));
            result ^= fy_direct_checksum(yyjson_obj_iter_get_val(key));
        }
    }
    return result;
}

static uint64_t fy_flat_checksum(FyFlatDocument *document) {
    uint64_t result = 0;
    for (uint32_t i = 0; i < document->node_count; i++)
        result ^= document->nodes[i].payload ^ document->nodes[i].aux ^ document->nodes[i].kind;
    for (uint32_t i = 0; i < document->object_count; i++)
        result ^= document->object_entries[i].value ^ document->object_entries[i].key.offset;
    return result;
}

uint64_t YJ_Yyjson_TraversalChecksum(uint64_t handle) {
    FyDocument *document = (FyDocument *)(uintptr_t)handle;
    if (document == NULL) return 0;
    if (document->fallback_custom_handle != 0)
        return YJ_Compact_TraversalChecksum(document->fallback_custom_handle);
    if (document->flat != NULL) return fy_flat_checksum(document->flat);
    return fy_direct_checksum(document->root);
}

int32_t YJ_Yyjson_RootSize(uint64_t handle, uint64_t *out_size) {
    FyDocument *document = (FyDocument *)(uintptr_t)handle;
    if (document == NULL) return YJ_COMPACT_CLOSED;
    if (out_size == NULL) return YJ_COMPACT_PARSE_ERROR;
    if (document->fallback_custom_handle != 0)
        return YJ_Compact_Size(document->fallback_custom_handle,
                               document->fallback_custom_root, out_size);
    if (document->flat != NULL) {
        FyNode *root = &document->flat->nodes[document->flat->root];
        *out_size = root->kind == YJ_COMPACT_ARRAY || root->kind == YJ_COMPACT_OBJECT
            ? root->aux : 0;
    } else {
        *out_size = yyjson_get_len(document->root);
    }
    return YJ_COMPACT_OK;
}

static int fy_build_root_index(FyDocument *document) {
    if (document->root_index != NULL) return 1;
    if (document->root == NULL || !yyjson_is_obj(document->root)) return 0;
    size_t count = yyjson_obj_size(document->root);
    if (count < 256u) return 1;
    FyDuplicateSet *set = (FyDuplicateSet *)calloc(1, sizeof(FyDuplicateSet));
    if (set == NULL || !fy_duplicate_init(set, count, &document->validation_scratch_peak)) {
        free(set);
        return 0;
    }
    yyjson_obj_iter iter = yyjson_obj_iter_with(document->root);
    yyjson_val *key;
    int duplicate = 0;
    while ((key = yyjson_obj_iter_next(&iter)) != NULL) {
        if (!fy_duplicate_find_or_insert(document, set, key, &duplicate) || duplicate) {
            fy_duplicate_free(set); free(set); return 0;
        }
    }
    document->root_index = set;
    document->root_index_bytes = (uint64_t)set->capacity * sizeof(uint64_t);
    document->root_index_builds++;
    return 1;
}

static yyjson_val *fy_index_lookup(FyDocument *document,
                                   const uint8_t *key, uint32_t length) {
    FyDuplicateSet *set = document->root_index;
    if (set == NULL || set->capacity == 0) return NULL;
    uint64_t hash = fy_hash_seeded(key, length, document->hash_seed);
    uint32_t fingerprint = fy_fingerprint(hash);
    uint32_t mask = set->capacity - 1u;
    uint32_t slot = (uint32_t)hash & mask;
    uint64_t probes = 0;
    uintptr_t base_address = (uintptr_t)document->root;
    while (1) {
        probes++;
        uint64_t prior_slot = set->slots[slot];
        if (prior_slot == 0) { fy_record_probe(document, probes, 1); return NULL; }
        yyjson_val *prior = (yyjson_val *)(void *)(base_address +
            (uint32_t)prior_slot);
        if ((uint32_t)(prior_slot >> 32) == fingerprint &&
            yyjson_get_len(prior) == length &&
            (length == 0 || memcmp(yyjson_get_str(prior), key, length) == 0)) {
            fy_record_probe(document, probes, 1);
            return yyjson_obj_iter_get_val(prior);
        }
        slot = (slot + 1u) & mask;
    }
}

static int fy_value_int64(yyjson_val *value, int64_t *out) {
    if (yyjson_is_raw(value))
        return fy_raw_int64(yyjson_get_raw(value), yyjson_get_len(value), out);
    if (yyjson_is_sint(value)) { *out = yyjson_get_sint(value); return 1; }
    if (yyjson_is_uint(value)) {
        uint64_t number = yyjson_get_uint(value);
        if (number <= (uint64_t)INT64_MAX) { *out = (int64_t)number; return 1; }
    }
    return 0;
}

int32_t YJ_Yyjson_ObjectLookupInt(uint64_t handle,
                                 const uint8_t *key, uint64_t key_length,
                                 int64_t *out_value, uint32_t *out_found) {
    FyDocument *document = (FyDocument *)(uintptr_t)handle;
    if (document == NULL) return YJ_COMPACT_CLOSED;
    if (key_length > SIZE_MAX || (key_length != 0 && key == NULL) ||
        out_value == NULL || out_found == NULL) return YJ_COMPACT_TYPE_ERROR;
    if (document->fallback_custom_handle != 0) {
        uint32_t kind = 0;
        uint64_t payload = 0;
        int32_t status = YJ_Compact_ObjectLookup(document->fallback_custom_handle,
            document->fallback_custom_root, key, key_length, &kind, &payload, out_found);
        if (status != YJ_COMPACT_OK || *out_found == 0) return status;
        if (kind != YJ_COMPACT_INT) return YJ_COMPACT_TYPE_ERROR;
        memcpy(out_value, &payload, sizeof(*out_value));
        return YJ_COMPACT_OK;
    }
    if (document->flat != NULL) {
        FyFlatDocument *flat = document->flat;
        FyNode *root = &flat->nodes[flat->root];
        if (root->kind != YJ_COMPACT_OBJECT) return YJ_COMPACT_TYPE_ERROR;
        for (uint32_t i = 0; i < root->aux; i++) {
            FyObjectEntry *entry = &flat->object_entries[root->payload + i];
            if (entry->key.length == key_length &&
                (key_length == 0 || memcmp(flat->strings + entry->key.offset, key,
                                           (size_t)key_length) == 0)) {
                FyNode *value = &flat->nodes[entry->value];
                if (value->kind != YJ_COMPACT_INT) return YJ_COMPACT_TYPE_ERROR;
                memcpy(out_value, &value->payload, sizeof(*out_value));
                *out_found = 1;
                return YJ_COMPACT_OK;
            }
        }
        *out_found = 0;
        return YJ_COMPACT_OK;
    }
    if ((document->flags & YJ_YYJSON_LAZY_ROOT_INDEX) != 0 &&
        document->root_index == NULL && yyjson_is_obj(document->root) &&
        yyjson_obj_size(document->root) >= 256u && !fy_build_root_index(document))
        return YJ_COMPACT_OUT_OF_MEMORY;
    yyjson_val *value = document->root_index == NULL
        ? yyjson_obj_getn(document->root, (const char *)key, (size_t)key_length)
        : fy_index_lookup(document, key, (uint32_t)key_length);
    if (value == NULL) { *out_found = 0; return YJ_COMPACT_OK; }
    if (!fy_value_int64(value, out_value))
        return YJ_COMPACT_TYPE_ERROR;
    *out_found = 1;
    return YJ_COMPACT_OK;
}

static int fy_buffer_reserve(FyBuffer *buffer, uint64_t extra) {
    if (extra > UINT64_MAX - buffer->size) return 0;
    uint64_t required = buffer->size + extra;
    if (required <= buffer->capacity) return 1;
    uint64_t next = buffer->capacity == 0 ? 256u : buffer->capacity;
    while (next < required) {
        if (next > UINT64_MAX / 2u) { next = required; break; }
        next *= 2u;
    }
    if (next > SIZE_MAX) return 0;
    void *replacement = realloc(buffer->data, (size_t)next);
    if (replacement == NULL) return 0;
    buffer->data = (uint8_t *)replacement;
    buffer->capacity = next;
    return 1;
}

static void fy_buffer_write(FyBuffer *buffer, const void *data, uint64_t length) {
    if (buffer->failed || !fy_buffer_reserve(buffer, length)) { buffer->failed = 1; return; }
    if (length != 0) memcpy(buffer->data + buffer->size, data, (size_t)length);
    buffer->size += length;
}

static void fy_buffer_byte(FyBuffer *buffer, uint8_t value) {
    fy_buffer_write(buffer, &value, 1);
}

static void fy_write_escaped(FyBuffer *buffer, const uint8_t *text, uint32_t length) {
    static const char hex[] = "0123456789abcdef";
    fy_buffer_byte(buffer, '"');
    for (uint32_t i = 0; i < length; i++) {
        uint8_t c = text[i];
        if (c == '"' || c == '\\') {
            fy_buffer_byte(buffer, '\\'); fy_buffer_byte(buffer, c);
        } else if (c == '\b') fy_buffer_write(buffer, "\\b", 2);
        else if (c == '\f') fy_buffer_write(buffer, "\\f", 2);
        else if (c == '\n') fy_buffer_write(buffer, "\\n", 2);
        else if (c == '\r') fy_buffer_write(buffer, "\\r", 2);
        else if (c == '\t') fy_buffer_write(buffer, "\\t", 2);
        else if (c < 0x20) {
            char escape[6] = {'\\', 'u', '0', '0', hex[c >> 4], hex[c & 15]};
            fy_buffer_write(buffer, escape, 6);
        } else fy_buffer_byte(buffer, c);
    }
    fy_buffer_byte(buffer, '"');
}

static void fy_flat_serialize_value(FyFlatDocument *document, uint32_t node_index,
                                    FyBuffer *buffer) {
    FyNode *node = &document->nodes[node_index];
    if (node->kind == YJ_COMPACT_NULL) { fy_buffer_write(buffer, "null", 4); return; }
    if (node->kind == YJ_COMPACT_BOOL) {
        fy_buffer_write(buffer, node->payload ? "true" : "false", node->payload ? 4 : 5); return;
    }
    if (node->kind == YJ_COMPACT_INT) {
        char text[32];
        int64_t value; memcpy(&value, &node->payload, sizeof(value));
        int length = snprintf(text, sizeof(text), "%lld", (long long)value);
        fy_buffer_write(buffer, text, (uint64_t)length); return;
    }
    if (node->kind == YJ_COMPACT_NUMBER || node->kind == YJ_COMPACT_STRING) {
        uint32_t offset = (uint32_t)(node->payload >> 32);
        uint32_t length = (uint32_t)node->payload;
        if (node->kind == YJ_COMPACT_NUMBER)
            fy_buffer_write(buffer, document->strings + offset, length);
        else fy_write_escaped(buffer, document->strings + offset, length);
        return;
    }
    if (node->kind == YJ_COMPACT_ARRAY) {
        fy_buffer_byte(buffer, '[');
        for (uint32_t i = 0; i < node->aux; i++) {
            if (i != 0) fy_buffer_byte(buffer, ',');
            fy_flat_serialize_value(document, document->array_entries[node->payload + i], buffer);
        }
        fy_buffer_byte(buffer, ']'); return;
    }
    fy_buffer_byte(buffer, '{');
    for (uint32_t i = 0; i < node->aux; i++) {
        if (i != 0) fy_buffer_byte(buffer, ',');
        FyObjectEntry *entry = &document->object_entries[node->payload + i];
        fy_write_escaped(buffer, document->strings + entry->key.offset, entry->key.length);
        fy_buffer_byte(buffer, ':');
        fy_flat_serialize_value(document, entry->value, buffer);
    }
    fy_buffer_byte(buffer, '}');
}

int32_t YJ_Yyjson_SerializeAlloc(uint64_t handle,
                                uint64_t *out_buffer_handle,
                                uint64_t *out_size) {
    FyDocument *document = (FyDocument *)(uintptr_t)handle;
    if (document == NULL) return YJ_COMPACT_CLOSED;
    if (out_buffer_handle == NULL || out_size == NULL) return YJ_COMPACT_PARSE_ERROR;
    FyOwnedBuffer *owned = (FyOwnedBuffer *)calloc(1, sizeof(FyOwnedBuffer));
    if (owned == NULL) return YJ_COMPACT_OUT_OF_MEMORY;
    if (document->fallback_custom_handle != 0) {
        uint64_t custom_buffer = 0, custom_size = 0;
        int32_t status = YJ_Compact_SerializeAlloc(document->fallback_custom_handle,
                                                   &custom_buffer, &custom_size);
        if (status != YJ_COMPACT_OK) { free(owned); return status; }
        owned->data = custom_size == 0 ? NULL : (uint8_t *)malloc((size_t)custom_size);
        owned->size = custom_size;
        if ((custom_size != 0 && owned->data == NULL) ||
            YJ_Compact_CopyOwnedBuffer(custom_buffer, owned->data, custom_size) != YJ_COMPACT_OK) {
            YJ_Compact_FreeOwnedBuffer(custom_buffer);
            free(owned->data); free(owned);
            return YJ_COMPACT_OUT_OF_MEMORY;
        }
        YJ_Compact_FreeOwnedBuffer(custom_buffer);
    } else if (document->flat == NULL) {
        size_t size = 0;
        char *text = yyjson_write(document->yy_doc, YYJSON_WRITE_NOFLAG, &size);
        if (text == NULL) { free(owned); return YJ_COMPACT_OUT_OF_MEMORY; }
        owned->data = (uint8_t *)text;
        owned->size = size;
    } else {
        FyBuffer buffer = {0};
        fy_flat_serialize_value(document->flat, document->flat->root, &buffer);
        if (buffer.failed) { free(buffer.data); free(owned); return YJ_COMPACT_OUT_OF_MEMORY; }
        owned->data = buffer.data;
        owned->size = buffer.size;
    }
    *out_buffer_handle = (uint64_t)(uintptr_t)owned;
    *out_size = owned->size;
    return YJ_COMPACT_OK;
}

int32_t YJ_Yyjson_CopyOwnedBuffer(uint64_t buffer_handle,
                                 uint8_t *output,
                                 uint64_t output_capacity) {
    FyOwnedBuffer *buffer = (FyOwnedBuffer *)(uintptr_t)buffer_handle;
    if (buffer == NULL) return YJ_COMPACT_CLOSED;
    if (output_capacity < buffer->size || (buffer->size != 0 && output == NULL))
        return YJ_COMPACT_BOUNDS_ERROR;
    if (buffer->size != 0) memcpy(output, buffer->data, (size_t)buffer->size);
    return YJ_COMPACT_OK;
}

void YJ_Yyjson_FreeOwnedBuffer(uint64_t buffer_handle) {
    FyOwnedBuffer *buffer = (FyOwnedBuffer *)(uintptr_t)buffer_handle;
    if (buffer == NULL) return;
    free(buffer->data);
    free(buffer);
}

static uint64_t fy_validation_percentile(FyDocument *document,
                                         uint64_t numerator,
                                         uint64_t denominator) {
    uint64_t total = 0;
    for (uint32_t i = 0; i < 32u; i++) total += document->validation_probe_histogram[i];
    if (total == 0) return 0;
    uint64_t target = (total * numerator + denominator - 1u) / denominator;
    uint64_t seen = 0;
    for (uint32_t i = 0; i < 32u; i++) {
        seen += document->validation_probe_histogram[i];
        if (seen >= target) return i == 31u ? document->validation_max_probe : i + 1u;
    }
    return document->validation_max_probe;
}

int32_t YJ_Yyjson_Stats(uint64_t handle, uint64_t *stats, uint64_t capacity) {
    FyDocument *document = (FyDocument *)(uintptr_t)handle;
    if (document == NULL) return YJ_COMPACT_CLOSED;
    if (stats == NULL || capacity < 12u) return YJ_COMPACT_BOUNDS_ERROR;
    stats[0] = document->allocator.current;
    stats[1] = document->allocator.peak;
    stats[2] = document->allocator.total;
    stats[3] = document->validation_scratch_peak;
    stats[4] = document->flat == NULL ? document->allocator.current
        : document->flat->persistent_used;
    stats[5] = document->flat == NULL ? document->allocator.current
        : document->flat->persistent_committed;
    stats[6] = document->node_count;
    stats[7] = document->object_fields;
    stats[8] = document->array_entries;
    stats[9] = document->string_count;
    stats[10] = document->mode;
    stats[11] = document->fallback_custom_handle != 0;
    if (capacity >= 14u) {
        stats[12] = document->validation_probes;
        stats[13] = document->validation_max_probe;
    }
    if (capacity >= 36u) {
        stats[14] = document->validation_hashes;
        stats[15] = document->validation_fingerprint_matches;
        stats[16] = document->validation_memcmp_calls;
        stats[17] = document->validation_memcmp_bytes;
        stats[18] = document->validation_small_linear_objects;
        stats[19] = document->validation_hashed_objects;
        stats[20] = document->validation_walks;
        stats[21] = document->literal_entries;
        stats[22] = document->literal_bytes;
        stats[23] = document->source_replay_bytes;
        stats[24] = document->source_copy_bytes;
        stats[25] = document->number_safe_ints;
        stats[26] = document->number_raw_required;
        stats[27] = document->root_index_bytes;
        stats[28] = document->root_index_builds;
        stats[29] = document->root_index_probes;
        stats[30] = document->root_index_max_probe;
        stats[31] = fy_validation_percentile(document, 1u, 2u);
        stats[32] = fy_validation_percentile(document, 95u, 100u);
        stats[33] = fy_validation_percentile(document, 99u, 100u);
        stats[34] = document->literal_source_size;
        stats[35] = document->flags;
    }
    return YJ_COMPACT_OK;
}

#if defined(YJ_TESTING)
uint32_t YJ_Yyjson_TestVendoredVersion(void) {
    return yyjson_version();
}
#endif
