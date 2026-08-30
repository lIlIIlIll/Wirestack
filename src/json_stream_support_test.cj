package yjson

import std.io.*
import std.collection.*

class MemoryOutputStream <: OutputStream {
    private let buffer = ArrayList<Byte>()

    public func write(bytes: Array<Byte>): Unit {
        buffer.add(all: bytes)
    }

    public func flush(): Unit {}

    public func toByteArray(): Array<Byte> {
        buffer.toArray()
    }

    public func toUtf8String(): String {
        String.fromUtf8(toByteArray())
    }
}

class ByteArrayInputStream <: InputStream {
    private let bytes: Array<Byte>
    private var start: Int64
    private var remain: Int64

    public init(bytes: Array<Byte>) {
        this.bytes = bytes
        this.start = 0
        this.remain = bytes.size
    }

    public init(text: String) {
        this(unsafe { text.rawData() })
    }

    public func read(buf: Array<Byte>): Int64 {
        if (remain == 0) {
            return 0
        }
        let size = if (buf.size <= remain) {
            buf.size
        } else {
            remain
        }
        bytes.copyTo(buf, start, 0, size)
        start += size
        remain -= size
        size
    }

}

class FixedChunkInputStream <: InputStream {
    private let bytes: Array<Byte>
    private let chunkSize: Int64
    private var start: Int64 = 0

    public init(text: String, chunkSize: Int64) {
        unsafe {
            this.bytes = text.rawData()
        }
        this.chunkSize = chunkSize
    }

    public func read(buf: Array<Byte>): Int64 {
        if (start >= bytes.size) {
            return 0
        }
        let remaining = bytes.size - start
        var readSize = chunkSize
        if (readSize > buf.size) {
            readSize = buf.size
        }
        if (readSize > remaining) {
            readSize = remaining
        }
        bytes.copyTo(buf, start, 0, readSize)
        start += readSize
        readSize
    }
}

/// Emits exactly one caller-selected prefix before exposing the remainder.
/// This catches tokens whose semantic state must survive every possible chunk
/// boundary without turning a zero-length read into a false end-of-input.
class SplitPointInputStream <: InputStream {
    private let bytes: Array<Byte>
    private let splitPoint: Int64
    private var start: Int64 = 0

    public init(text: String, splitPoint: Int64) {
        unsafe { this.bytes = text.rawData() }
        this.splitPoint = splitPoint
    }

    public init(bytes: Array<Byte>, splitPoint: Int64) {
        this.bytes = bytes
        this.splitPoint = splitPoint
    }

    public func read(buf: Array<Byte>): Int64 {
        if (start >= bytes.size) { return 0 }
        let boundary = if (start < splitPoint) { splitPoint } else { bytes.size }
        var readSize = boundary - start
        if (readSize > buf.size) { readSize = buf.size }
        bytes.copyTo(buf, start, 0, readSize)
        start += readSize
        readSize
    }
}
