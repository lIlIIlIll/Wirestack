package wirestack

/**
 * A checked, non-copying view over an immutable byte range.
 *
 * `ByteSpan` keeps the supplied array and describes a half-open range within
 * it. Constructing, slicing and advancing a span never clone the array.
 */
public struct ByteSpan {
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let bytes: Array<Byte>
/**
 * Wirestack 公开 API：返回当前对象保存的受约束值。
 */
    public let offset: Int64
/**
 * Wirestack 公开 API：返回当前对象保存的受约束值。
 */
    public let length: Int64

/**
 * Wirestack 公开 API：构造并校验该公开值。
 * @param bytes 保存原始内容的字节序列。
 * @param length 允许处理的字节数。
 * @param offset 从序列起始处计算的偏移量。
 */
    public init(bytes: Array<Byte>, offset!: Int64 = 0, length!: Int64 = bytes.size) {
        validateSpanRange(bytes.size, offset, length)
        this.bytes = bytes
        this.offset = offset
        this.length = length
    }

/**
 * Wirestack 公开 API：报告当前集合是否没有元素。
 */
    public func isEmpty(): Bool {
        length == 0
    }

/**
 * Returns a view relative to this span.
 * @param length 允许处理的字节数。
 * @param relativeOffset 相对于当前序列位置的偏移量。
 */
    public func slice(relativeOffset: Int64, length!: Int64 = this.length - relativeOffset): ByteSpan {
        validateSpanRange(this.length, relativeOffset, length)
        ByteSpan(bytes, offset: offset + relativeOffset, length: length)
    }

/**
 * Returns the unconsumed suffix after advancing `count` bytes.
 * @param count 要处理的元素数量。
 */
    public func advance(count: Int64): ByteSpan {
        slice(count)
    }
}

/** A checked, non-copying view over a mutable byte range. */
public struct MutableByteSpan {
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let bytes: Array<Byte>
/**
 * Wirestack 公开 API：返回当前对象保存的受约束值。
 */
    public let offset: Int64
/**
 * Wirestack 公开 API：返回当前对象保存的受约束值。
 */
    public let length: Int64

/**
 * Wirestack 公开 API：构造并校验该公开值。
 * @param bytes 保存原始内容的字节序列。
 * @param length 允许处理的字节数。
 * @param offset 从序列起始处计算的偏移量。
 */
    public init(bytes: Array<Byte>, offset!: Int64 = 0, length!: Int64 = bytes.size) {
        validateSpanRange(bytes.size, offset, length)
        this.bytes = bytes
        this.offset = offset
        this.length = length
    }

/**
 * Wirestack 公开 API：报告当前集合是否没有元素。
 */
    public func isEmpty(): Bool {
        length == 0
    }

/**
 * Returns a mutable view relative to this span.
 * @param length 允许处理的字节数。
 * @param relativeOffset 相对于当前序列位置的偏移量。
 */
    public func slice(relativeOffset: Int64, length!: Int64 = this.length - relativeOffset): MutableByteSpan {
        validateSpanRange(this.length, relativeOffset, length)
        MutableByteSpan(bytes, offset: offset + relativeOffset, length: length)
    }

/**
 * Returns the unfilled suffix after advancing `count` bytes.
 * @param count 要处理的元素数量。
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
