package wirestack.internal.transport

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

private class ChunkedTestTransport <: DuplexTransport {
    private let input: Array<Byte>
    private var readOffset: Int64 = 0
    private let maxChunk: Int64
    private let output = ArrayList<Byte>()
    private var closed = false

    init(input: Array<Byte>, maxChunk!: Int64 = 2) {
        this.input = input
        this.maxChunk = maxChunk
    }

    public prop info: TransportInfo {
        get() { TransportInfo("test") }
    }

    public func readSome(
        destination: MutableByteSpan,
        context!: OperationContext = OperationContext.background()
    ): ReadResult {
        let _ = context
        if (destination.isEmpty()) {
            return ReadResult.Data(0)
        }
        if (readOffset >= input.size) {
            return ReadResult.EndOfStream
        }
        let count = min(destination.length, min(maxChunk, input.size - readOffset))
        for (index in 0..count) {
            destination.bytes[destination.offset + index] = input[readOffset + index]
        }
        readOffset += count
        ReadResult.Data(count)
    }

    public func writeSome(
        source: ByteSpan,
        context!: OperationContext = OperationContext.background()
    ): Int64 {
        let _ = context
        if (source.isEmpty()) {
            return 0
        }
        let count = min(source.length, maxChunk)
        for (index in 0..count) {
            output.add(source.bytes[source.offset + index])
        }
        count
    }

    public func shutdown(_: ShutdownDirection): Unit {}
    public func close(context: OperationContext): Unit { let _ = context; closed = true }
    public func abort(reason!: ?AbortReason): Unit { let _ = reason; closed = true }
    public func close(): Unit { close(OperationContext.background()) }
    public func isClosed(): Bool { closed }

    func written(): Array<Byte> { output.toArray() }
}

@Test
class TransportHelperTest {
    @TestCase
    func writeAllHandlesPartialWritesAndEmptyInput(): Unit {
        let transport = ChunkedTestTransport([])
        writeAll(transport, ByteSpan([1, 2, 3, 4, 5]))
        writeAll(transport, ByteSpan([]))
        let expected: Array<Byte> = [1, 2, 3, 4, 5]
        @Expect(transport.written(), expected)
    }

    @TestCase
    func readExactHandlesPartialReads(): Unit {
        let transport = ChunkedTestTransport([1, 2, 3, 4, 5])
        let destination = Array<Byte>(5, repeat: 0)
        readExact(transport, MutableByteSpan(destination))
        let expected: Array<Byte> = [1, 2, 3, 4, 5]
        @Expect(destination, expected)
    }

    @TestCase
    func readExactClassifiesPrematureEof(): Unit {
        let transport = ChunkedTestTransport([1, 2])
        var classified = false
        try {
            readExact(transport, MutableByteSpan(Array<Byte>(3, repeat: 0)))
        } catch (error: NetworkException) {
            match (error.code) {
                case NetworkErrorCode.UnexpectedEof => classified = true
                case _ => ()
            }
        }
        @Expect(classified)
    }

    @TestCase
    func emptyBuffersDoNotImplyEofOrWriteProgress(): Unit {
        let transport = ChunkedTestTransport([])
        match (transport.readSome(MutableByteSpan([]))) {
            case ReadResult.Data(count) => @Expect(count, 0)
            case ReadResult.EndOfStream => @Expect(false)
        }
        @Expect(transport.writeSome(ByteSpan([])), 0)
    }
}
