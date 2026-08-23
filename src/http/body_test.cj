package wirestack.http

import std.collection.ArrayList
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class RequestBodyTest {
    @TestCase
    func byteBodiesOwnInputAndReplayWithIndependentOffsets(): Unit {
        let input = "hello".toArray()
        let body = RequestBody.bytes(input)
        input[0] = b'X'

        let first = body.open()
        let second = body.open()
        try {
            let small = Array<Byte>(2, repeat: 0)
            @Expect(first.read(small), 2)
            @Expect(String.fromUtf8(small), "he")
            @Expect(readAllBody(first), "llo")
            @Expect(readAllBody(second), "hello")
            @Expect(body.contentLength, Some(5))
            @Expect(body.replayability, BodyReplayability.Replayable)
        } finally {
            first.close()
            second.close()
        }
    }

    @TestCase
    func emptyAndUtf8StringBodiesHaveExactLengths(): Unit {
        let empty = RequestBody.empty().open()
        let textBody = RequestBody.string("仓颉")
        let text = textBody.open()
        try {
            @Expect(empty.read(Array<Byte>(1, repeat: 0)), 0)
            @Expect(readAllBody(text), "仓颉")
            @Expect(textBody.contentLength, Some("仓颉".toArray().size))
        } finally {
            empty.close()
            text.close()
        }
    }

    @TestCase
    func oneShotBodyCanOnlyBeClaimedOnce(): Unit {
        let stream = TestBodyStream("one".toArray(), Some(3))
        let body = RequestBody.oneShot(stream)
        let opened = body.open()
        @Expect(readAllBody(opened), "one")
        @Expect(body.replayability, BodyReplayability.OneShot)
        expectBodyFailure(HttpBodyErrorCode.AlreadyOpened, { => let _ = body.open() })
        stream.close()
    }

    @TestCase
    func factoryMustReturnTheDeclaredLengthAndMismatchIsClosed(): Unit {
        let returned = TestBodyStream("bad".toArray(), Some(3))
        let body = RequestBody.replayableFactory(Some(4), { => returned })

        expectBodyFailure(HttpBodyErrorCode.FactoryContractViolation, { => let _ = body.open() })
        @Expect(returned.isClosed())
    }

    @TestCase
    func closedStreamRejectsFurtherReads(): Unit {
        let stream = RequestBody.bytes("x".toArray()).open()
        stream.close()
        expectBodyFailure(HttpBodyErrorCode.Closed, {
            => let _ = stream.read(Array<Byte>(1, repeat: 0))
        })
    }

    @TestCase
    func fileBodyStreamsAndReopensWithoutEagerReads(): Unit {
        let temporary = File.createTemp("/tmp")
        let path = temporary.info.path.toString()
        temporary.close()
        try {
            File.writeTo(path, "streamed-file".toArray())
            let body = RequestBody.file(path, maximumBytes: 64)
            let first = body.open()
            let second = body.open()
            try {
                let prefix = Array<Byte>(3, repeat: 0)
                @Expect(first.read(prefix), 3)
                @Expect(String.fromUtf8(prefix), "str")
                @Expect(readAllBody(first), "eamed-file")
                @Expect(readAllBody(second), "streamed-file")
            } finally {
                first.close()
                second.close()
            }
        } finally {
            remove(path)
        }
    }

    @TestCase
    func fileBodyRejectsOversizeAndChangesBeforeOpen(): Unit {
        let temporary = File.createTemp("/tmp")
        let path = temporary.info.path.toString()
        temporary.close()
        try {
            File.writeTo(path, "before".toArray())
            expectBodyFailure(HttpBodyErrorCode.InvalidFile, {
                => let _ = RequestBody.file(path, maximumBytes: 2)
            })

            let body = RequestBody.file(path)
            File.writeTo(path, "after-change".toArray())
            expectBodyFailure(HttpBodyErrorCode.FileChanged, { => let _ = body.open() })
        } finally {
            remove(path)
        }
    }
}

private class TestBodyStream <: HttpBodyStream {
    private let data: Array<Byte>
    private let declaredLength: ?Int64
    private var offset: Int64 = 0
    private var closed = false

    init(data: Array<Byte>, declaredLength: ?Int64) {
        this.data = data.clone()
        this.declaredLength = declaredLength
    }

    public prop contentLength: ?Int64 { get() { declaredLength } }

    public func read(destination: Array<Byte>): Int64 {
        if (closed) { throw HttpBodyException(HttpBodyErrorCode.Closed, "closed test body") }
        if (destination.isEmpty() || offset == data.size) { return 0 }
        let count = min(destination.size, data.size - offset)
        for (index in 0..count) { destination[index] = data[offset + index] }
        offset += count
        count
    }

    public func close(): Unit { closed = true }
    public func isClosed(): Bool { closed }
}

private func readAllBody(stream: HttpBodyStream): String {
    let buffer = Array<Byte>(3, repeat: 0)
    let output = ArrayList<Byte>()
    while (true) {
        let count = stream.read(buffer)
        if (count == 0) { break }
        for (index in 0..count) { output.add(buffer[index]) }
    }
    String.fromUtf8(output.toArray())
}

private func expectBodyFailure(code: HttpBodyErrorCode, action: () -> Unit): Unit {
    var matched = false
    try {
        action()
    } catch (error: HttpBodyException) {
        matched = sameBodyCode(error.code, code)
    }
    @Expect(matched)
}

private func sameBodyCode(left: HttpBodyErrorCode, right: HttpBodyErrorCode): Bool {
    match ((left, right)) {
        case (HttpBodyErrorCode.Closed, HttpBodyErrorCode.Closed) => true
        case (HttpBodyErrorCode.ConcurrentRead, HttpBodyErrorCode.ConcurrentRead) => true
        case (HttpBodyErrorCode.AlreadyOpened, HttpBodyErrorCode.AlreadyOpened) => true
        case (HttpBodyErrorCode.InvalidLength, HttpBodyErrorCode.InvalidLength) => true
        case (HttpBodyErrorCode.InvalidFile, HttpBodyErrorCode.InvalidFile) => true
        case (HttpBodyErrorCode.FileChanged, HttpBodyErrorCode.FileChanged) => true
        case (HttpBodyErrorCode.PrematureEof, HttpBodyErrorCode.PrematureEof) => true
        case (HttpBodyErrorCode.FactoryContractViolation, HttpBodyErrorCode.FactoryContractViolation) => true
        case _ => false
    }
}
