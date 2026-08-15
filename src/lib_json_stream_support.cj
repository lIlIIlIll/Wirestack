package yjson

import std.collection.*
import std.io.*

/// In-memory output stream used by the public streaming codec API and examples.
public class YJsonMemoryOutputStream <: OutputStream {
    private let buffer = ArrayList<Byte>()
    public func write(bytes: Array<Byte>): Unit { buffer.add(all: bytes) }
    public func flush(): Unit {}
    public func toByteArray(): Array<Byte> { buffer.toArray() }
    public func toUtf8String(): String { String.fromUtf8(toByteArray()) }
}

/// In-memory input stream with a bulk unread-byte operation for YJson.
public class YJsonByteArrayInputStream <: InputStream {
    private let bytes: Array<Byte>
    private var start: Int64 = 0
    private var remain: Int64

    public init(bytes: Array<Byte>) {
        this.bytes = bytes
        this.remain = bytes.size
    }

    public init(text: String) { this(unsafe { text.rawData() }) }

    public func read(buf: Array<Byte>): Int64 {
        if (remain == 0) { return 0 }
        let size = if (buf.size <= remain) { buf.size } else { remain }
        bytes.copyTo(buf, start, 0, size)
        start += size
        remain -= size
        size
    }

    public func readRemainingBytes(): Array<Byte> {
        let result = bytes[start..start + remain]
        start += remain
        remain = 0
        result
    }
}
