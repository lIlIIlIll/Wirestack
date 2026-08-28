package wirestack.internal.transport

import std.unittest.*
import std.unittest.testmacro.*

private func expectIllegalArgument(action: () -> Unit): Unit {
    var thrown = false
    try {
        action()
    } catch (_: IllegalArgumentException) {
        thrown = true
    }
    @Expect(thrown)
}

@Test
class ByteSpanTest {
    @TestCase
    func defaultsCoverWholeArrayAndEmptyArray(): Unit {
        let bytes: Array<Byte> = [1, 2, 3]
        let span = ByteSpan(bytes)
        @Expect(span.offset, 0)
        @Expect(span.length, 3)
        @Expect(!span.isEmpty())

        let empty = ByteSpan(Array<Byte>())
        @Expect(empty.offset, 0)
        @Expect(empty.length, 0)
        @Expect(empty.isEmpty())
    }

    @TestCase
    func sliceAndAdvanceKeepTheOriginalArray(): Unit {
        let bytes: Array<Byte> = [10, 20, 30, 40]
        let span = ByteSpan(bytes, offset: 1, length: 3)
        let middle = span.slice(1, length: 1)
        let suffix = span.advance(2)

        @Expect(middle.offset, 2)
        @Expect(middle.length, 1)
        @Expect(middle.bytes[2], 30)
        @Expect(suffix.offset, 3)
        @Expect(suffix.length, 1)

        bytes[2] = 99
        @Expect(middle.bytes[2], 99)
    }

    @TestCase
    func mutableViewWritesThroughAndConvertsWithoutCopying(): Unit {
        let bytes: Array<Byte> = [1, 2, 3]
        let target = MutableByteSpan(bytes, offset: 1, length: 2).slice(1)
        target.bytes[target.offset] = 9
        let source = target.asByteSpan()

        @Expect(bytes[2], 9)
        @Expect(source.offset, 2)
        @Expect(source.length, 1)
        @Expect(source.bytes[2], 9)
    }

    @TestCase
    func permitsBoundaryEmptyRanges(): Unit {
        let bytes: Array<Byte> = [1, 2]
        let end = ByteSpan(bytes, offset: 2, length: 0)
        let advanced = ByteSpan(bytes).advance(2)

        @Expect(end.isEmpty())
        @Expect(advanced.offset, 2)
        @Expect(advanced.length, 0)
    }

    @TestCase
    func rejectsEveryOutOfRangeShape(): Unit {
        let bytes: Array<Byte> = [1, 2, 3]
        expectIllegalArgument { => let _ = ByteSpan(bytes, offset: -1, length: 1) }
        expectIllegalArgument { => let _ = ByteSpan(bytes, offset: 0, length: -1) }
        expectIllegalArgument { => let _ = ByteSpan(bytes, offset: 4, length: 0) }
        expectIllegalArgument { => let _ = ByteSpan(bytes, offset: 2, length: 2) }
        expectIllegalArgument { => let _ = ByteSpan(bytes).slice(-1, length: 0) }
        expectIllegalArgument { => let _ = ByteSpan(bytes).slice(2, length: 2) }
        expectIllegalArgument { => let _ = ByteSpan(bytes).advance(4) }
        expectIllegalArgument { => let _ = MutableByteSpan(bytes, offset: 3, length: 1) }
        expectIllegalArgument { => let _ = MutableByteSpan(bytes).slice(-1, length: 0) }
        expectIllegalArgument { => let _ = MutableByteSpan(bytes).advance(4) }
    }
}
