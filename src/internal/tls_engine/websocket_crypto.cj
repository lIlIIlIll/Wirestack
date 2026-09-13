package wirestack.internal.tls_engine

private const WEBSOCKET_NATIVE_OK: Int32 = 0
private const WEBSOCKET_SHA1_BASE64_CAPACITY: Int64 = 29
private const WEBSOCKET_CRYPTO_INPUT_LIMIT: Int64 = 1024

foreign func wirestack_tls_websocket_random(
    output: CPointer<UInt8>,
    size: UInt64
): Int32

foreign func wirestack_tls_websocket_base64(
    input: CPointer<UInt8>,
    size: UInt64,
    output: CPointer<UInt8>,
    outputCapacity: UInt64,
    outSize: CPointer<UInt64>
): Int32

foreign func wirestack_tls_websocket_sha1_base64(
    input: CPointer<UInt8>,
    size: UInt64,
    output: CPointer<UInt8>,
    outputCapacity: UInt64,
    outSize: CPointer<UInt64>
): Int32

/** Module-private audited AWS-LC random bytes for WebSocket masks and handshake keys. */
protected func secureWebSocketRandom(size: Int64): Array<Byte> {
    if (size <= 0 || size > WEBSOCKET_CRYPTO_INPUT_LIMIT) {
        throw IllegalArgumentException("WebSocket random byte count is outside the private crypto bound")
    }
    let output = Array<Byte>(size, repeat: 0u8)
    let status = unsafe {
        let raw = acquireArrayRawData(output)
        try {
            wirestack_tls_websocket_random(raw.pointer, UInt64(size))
        } finally {
            releaseArrayRawData(raw)
        }
    }
    requireWebSocketCryptoStatus(status, "secure random generation")
    output
}

/** Module-private base64 with native output size excluding the required terminator. */
protected func webSocketBase64(input: Array<Byte>): String {
    if (input.isEmpty() || input.size > WEBSOCKET_CRYPTO_INPUT_LIMIT) {
        throw IllegalArgumentException("WebSocket base64 input is outside the private crypto bound")
    }
    let encodedBytes = 4 * ((input.size + 2) / 3)
    webSocketNativeText(input, encodedBytes + 1, sha1: false)
}

/** Module-private SHA-1 plus base64 used only by the RFC 6455 accept-key construction. */
protected func webSocketSha1Base64(input: Array<Byte>): String {
    if (input.isEmpty() || input.size > WEBSOCKET_CRYPTO_INPUT_LIMIT) {
        throw IllegalArgumentException("WebSocket accept input is outside the private crypto bound")
    }
    webSocketNativeText(input, WEBSOCKET_SHA1_BASE64_CAPACITY, sha1: true)
}

private func webSocketNativeText(input: Array<Byte>, capacity: Int64, sha1!: Bool): String {
    let output = Array<Byte>(capacity, repeat: 0u8)
    let outputSize = Array<UInt64>(1, repeat: 0u64)
    let status = unsafe {
        let source = acquireArrayRawData(input)
        let destination = acquireArrayRawData(output)
        let length = acquireArrayRawData(outputSize)
        try {
            if (sha1) {
                wirestack_tls_websocket_sha1_base64(
                    source.pointer,
                    UInt64(input.size),
                    destination.pointer,
                    UInt64(output.size),
                    length.pointer
                )
            } else {
                wirestack_tls_websocket_base64(
                    source.pointer,
                    UInt64(input.size),
                    destination.pointer,
                    UInt64(output.size),
                    length.pointer
                )
            }
        } finally {
            releaseArrayRawData(length)
            releaseArrayRawData(destination)
            releaseArrayRawData(source)
        }
    }
    requireWebSocketCryptoStatus(status, if (sha1) { "SHA-1/base64" } else { "base64" })
    let exactSize = Int64(outputSize[0])
    if (exactSize < 0 || exactSize >= output.size || output[exactSize] != 0u8) {
        throw IllegalStateException("WebSocket native crypto returned an invalid terminated length")
    }
    let exact = Array<Byte>(exactSize, repeat: 0u8)
    for (index in 0..exact.size) { exact[index] = output[index] }
    String.fromUtf8(exact)
}

private func requireWebSocketCryptoStatus(status: Int32, operation: String): Unit {
    if (status != WEBSOCKET_NATIVE_OK) {
        throw IllegalStateException("WebSocket ${operation} failed with native status ${status}")
    }
}
