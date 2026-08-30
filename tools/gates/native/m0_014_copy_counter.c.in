#include <stdint.h>

extern int32_t __real_CJ_SOCKET_BufferRCopy(
    void* socket_buffer,
    const char* array_buffer,
    int64_t buffer_length,
    int32_t copy_length
);

static uint64_t copied_bytes = 0;
static uint64_t copy_calls = 0;

int32_t __wrap_CJ_SOCKET_BufferRCopy(
    void* socket_buffer,
    const char* array_buffer,
    int64_t buffer_length,
    int32_t copy_length
) {
    int32_t result = __real_CJ_SOCKET_BufferRCopy(
        socket_buffer, array_buffer, buffer_length, copy_length
    );
    if (result > 0) {
        copied_bytes += (uint64_t)result;
        copy_calls += 1;
    }
    return result;
}

uint64_t WIRESTACK_M0014_CopyBytes(void) {
    return copied_bytes;
}

uint64_t WIRESTACK_M0014_CopyCalls(void) {
    return copy_calls;
}
