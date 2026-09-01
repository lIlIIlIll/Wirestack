#ifndef WIRESTACK_POC_ALLOCATION_PROFILE_H
#define WIRESTACK_POC_ALLOCATION_PROFILE_H

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#if defined(_MSC_VER)
typedef union __declspec(align(16)) PocAllocationHeader {
    struct {
        size_t size;
    } metadata;
    unsigned char alignment[16];
} PocAllocationHeader;
#else
typedef union PocAllocationHeader {
    struct {
        size_t size;
    } metadata;
    max_align_t alignment;
} PocAllocationHeader;
#endif

static uint64_t provider_allocation_calls = 0;
static uint64_t provider_allocation_bytes = 0;
static uint64_t provider_allocation_live_bytes = 0;
static uint64_t provider_allocation_peak_live_bytes = 0;
static int provider_allocation_diagnostic_mode = 0;

static inline void poc_profile_record_allocation(size_t size) {
    provider_allocation_calls++;
    provider_allocation_bytes += (uint64_t)size;
    provider_allocation_live_bytes += (uint64_t)size;
    if (provider_allocation_live_bytes > provider_allocation_peak_live_bytes) {
        provider_allocation_peak_live_bytes = provider_allocation_live_bytes;
    }
}

static inline void *poc_profile_malloc(size_t size) {
    if (provider_allocation_diagnostic_mode) {
        void *pointer = malloc(size);
        if (pointer != NULL) {
            provider_allocation_calls++;
            provider_allocation_bytes += (uint64_t)size;
            if ((uint64_t)size > provider_allocation_peak_live_bytes) {
                provider_allocation_peak_live_bytes = (uint64_t)size;
            }
        }
        return pointer;
    }
    if (size > SIZE_MAX - sizeof(PocAllocationHeader)) return NULL;
    PocAllocationHeader *header = malloc(sizeof(PocAllocationHeader) + size);
    if (header == NULL) return NULL;
    header->metadata.size = size;
    poc_profile_record_allocation(size);
    return header + 1;
}

static inline void *poc_profile_calloc(size_t count, size_t size) {
    if (size != 0 && count > SIZE_MAX / size) return NULL;
    size_t total = count * size;
    void *pointer = poc_profile_malloc(total);
    if (pointer != NULL) memset(pointer, 0, total);
    return pointer;
}

static inline void *poc_profile_realloc(void *pointer, size_t size) {
    if (provider_allocation_diagnostic_mode) {
        void *resized = realloc(pointer, size);
        if (resized != NULL) {
            provider_allocation_calls++;
            provider_allocation_bytes += (uint64_t)size;
            if ((uint64_t)size > provider_allocation_peak_live_bytes) {
                provider_allocation_peak_live_bytes = (uint64_t)size;
            }
        }
        return resized;
    }
    if (pointer == NULL) return poc_profile_malloc(size);
    if (size > SIZE_MAX - sizeof(PocAllocationHeader)) return NULL;
    PocAllocationHeader *old_header = ((PocAllocationHeader *)pointer) - 1;
    size_t old_size = old_header->metadata.size;
    PocAllocationHeader *new_header = realloc(
        old_header, sizeof(PocAllocationHeader) + size);
    if (new_header == NULL) return NULL;
    new_header->metadata.size = size;
    provider_allocation_calls++;
    provider_allocation_bytes += (uint64_t)size;
    provider_allocation_live_bytes -= (uint64_t)old_size;
    provider_allocation_live_bytes += (uint64_t)size;
    if (provider_allocation_live_bytes > provider_allocation_peak_live_bytes) {
        provider_allocation_peak_live_bytes = provider_allocation_live_bytes;
    }
    return new_header + 1;
}

static inline void poc_profile_free(void *pointer) {
    if (pointer == NULL) return;
    if (provider_allocation_diagnostic_mode) {
        free(pointer);
        return;
    }
    PocAllocationHeader *header = ((PocAllocationHeader *)pointer) - 1;
    provider_allocation_live_bytes -= (uint64_t)header->metadata.size;
    free(header);
}

#endif
