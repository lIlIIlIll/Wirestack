package wirestack

/**
 * A checked, non-copying view over an immutable byte range.
 *
 * `ByteSpan` keeps the supplied array and describes a half-open range within
 * it. Constructing, slicing and advancing a span never clone the array.
 */
public struct ByteSpan {
/**
 * Wirestack 公开 API：bytes。
 */
    public let bytes: Array<Byte>
/**
 * Wirestack 公开 API：offset。
 */
    public let offset: Int64
/**
 * Wirestack 公开 API：length。
 */
    public let length: Int64

/**
 * Wirestack 公开 API：init。
 * @param bytes 参数 bytes。
 * @param length 参数 length。
 * @param offset 参数 offset。
 */
    public init(bytes: Array<Byte>, offset!: Int64 = 0, length!: Int64 = bytes.size) {
        validateSpanRange(bytes.size, offset, length)
        this.bytes = bytes
        this.offset = offset
        this.length = length
    }

/**
 * Wirestack 公开 API：isEmpty。
 */
    public func isEmpty(): Bool {
        length == 0
    }

/**
 * Returns a view relative to this span.
 * @param length 参数 length。
 * @param relativeOffset 参数 relativeOffset。
 */
    public func slice(relativeOffset: Int64, length!: Int64 = this.length - relativeOffset): ByteSpan {
        validateSpanRange(this.length, relativeOffset, length)
        ByteSpan(bytes, offset: offset + relativeOffset, length: length)
    }

/**
 * Returns the unconsumed suffix after advancing `count` bytes.
 * @param count 参数 count。
 */
    public func advance(count: Int64): ByteSpan {
        slice(count)
    }
}

/** A checked, non-copying view over a mutable byte range. */
public struct MutableByteSpan {
/**
 * Wirestack 公开 API：bytes。
 */
    public let bytes: Array<Byte>
/**
 * Wirestack 公开 API：offset。
 */
    public let offset: Int64
/**
 * Wirestack 公开 API：length。
 */
    public let length: Int64

/**
 * Wirestack 公开 API：init。
 * @param bytes 参数 bytes。
 * @param length 参数 length。
 * @param offset 参数 offset。
 */
    public init(bytes: Array<Byte>, offset!: Int64 = 0, length!: Int64 = bytes.size) {
        validateSpanRange(bytes.size, offset, length)
        this.bytes = bytes
        this.offset = offset
        this.length = length
    }

/**
 * Wirestack 公开 API：isEmpty。
 */
    public func isEmpty(): Bool {
        length == 0
    }

/**
 * Returns a mutable view relative to this span.
 * @param length 参数 length。
 * @param relativeOffset 参数 relativeOffset。
 */
    public func slice(relativeOffset: Int64, length!: Int64 = this.length - relativeOffset): MutableByteSpan {
        validateSpanRange(this.length, relativeOffset, length)
        MutableByteSpan(bytes, offset: offset + relativeOffset, length: length)
    }

/**
 * Returns the unfilled suffix after advancing `count` bytes.
 * @param count 参数 count。
 */
    public func advance(count: Int64): MutableByteSpan {
        slice(count)
    }

    /** Exposes the same range as a read-only transport input view. */
    public func asByteSpan(): ByteSpan {
        ByteSpan(bytes, offset: offset, length: length)
    }
}

private func validateSpanRange(arraySize: Int64, offset: Int64, length: Int64): Unit {
    // The subtraction form avoids accepting an overflowing offset + length.
    if (offset < 0 || length < 0 || offset > arraySize || length > arraySize - offset) {
        throw IllegalArgumentException(
            "byte span [${offset}, ${offset}+${length}) is outside array size ${arraySize}"
        )
    }
}
