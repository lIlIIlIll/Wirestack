package wirestack.gzip
import wirestack.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import std.time.MonoTime

internal class GzipFixtureSource <: HttpBodyStream {
    private let bytes: Array<Byte>
    private let chunk: Int64
    private var offset: Int64 = 0
    private var closed = false
    internal var reads: Int64 = 0
    internal var closes: Int64 = 0
    internal var beforeRead: () -> Unit = { => () }
    private let throwsOnClose: Bool
    internal init(bytes: Array<Byte>, chunk!: Int64 = 1, throwsOnClose!: Bool = false) {
        this.bytes = bytes; this.chunk = chunk; this.throwsOnClose = throwsOnClose
    }
    public prop contentLength: ?Int64 { get() { Some(bytes.size) } }
    public func read(destination: Array<Byte>): Int64 {
        if (closed) { throw HttpBodyException(HttpBodyErrorCode.Closed, "fixture closed") }
        beforeRead()
        reads++
        let count = min(min(destination.size, chunk), bytes.size - offset)
        for (index in 0..count) { destination[index] = bytes[offset + index] }
        offset += count; count
    }
    public func close(): Unit {
        closed = true; closes++
        if (throwsOnClose) { throw IllegalStateException("fixture close failed") }
    }
    public func isClosed(): Bool { closed }
}
private class GzipCodecClock <: MonotonicClock {
    private var instant = MonoTime.now()
    func advance(duration: Duration): Unit { instant = instant + duration }
    public func now(): MonoTime { instant }
}
internal func gzipHex(value: String): Array<Byte> {
    let text = value.toArray(); let result = Array<Byte>(text.size / 2, repeat: 0)
    for (index in 0..result.size) {
        let a = text[index * 2]; let b = text[index * 2 + 1]
        let high = if (a <= b'9') { a - b'0' } else { a - b'a' + 10u8 }
        let low = if (b <= b'9') { b - b'0' } else { b - b'a' + 10u8 }
        result[index] = (high << 4) | low
    }
    result
}
internal func gzipDrain(body: GzipBodyStream): Array<Byte> {
    let result = ArrayList<Byte>(); let buffer = Array<Byte>(37, repeat: 0)
    // The absolute output bound and this call bound prevent a broken codec hanging a test.
    for (_ in 0..200000) {
        let count = body.read(buffer)
        if (count == 0) { return result.toArray() }
        if (count < 0 || count > buffer.size) { throw IllegalStateException("invalid decoded progress") }
        for (index in 0..count) { result.add(buffer[index]) }
    }
    throw IllegalStateException("gzip did not terminate within bounded reads")
}
internal func gzipFailure(bytes: Array<Byte>, limits: GzipLimits): GzipErrorCode {
    let source = GzipFixtureSource(bytes)
    let body = GzipBodyStream(source, limits: limits)
    try { let _ = gzipDrain(body) }
    catch (error: GzipException) {
        if (!source.isClosed() || !body.isClosed() || body.integrityVerified) {
            throw IllegalStateException("failed gzip body retained ownership or reported integrity")
        }
        return error.code
    }
    throw IllegalStateException("invalid gzip was accepted")
}
internal let gzipFixtureStored: String = "1f8b08000000000000ff010a00f5ff68656c6c6f20677a6970196ad2df0a000000"
internal let gzipFixtureFixed: String = "1f8b08000000000000ffcb48cdc9c95748afca2c0000196ad2df0a000000"
internal let gzipFixtureDynamic: String = "1f8b08000000000000ffedc4470d0000080430adc7f06f011d24eda3a99e8d2449922449922449922449922449bf3bfd411ac710270000"
internal let gzipFixtureBomb: String = "1f8b08000000000000ffedc13101000000c2a06ceb5fcac31a4001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000dc0076aac30f00000200"
internal let gzipFixtureEmpty: String = "1f8b08000000000000ff03000000000000000000"
internal let gzipFixtureOptional: String = "1f8b081e0000000000ff030078797a6e616d6500636f6d6d656e7400a5d2cb48cdc9c95748afca2c0000196ad2df0a000000"

@Test
class GzipCodecTest {
    @TestCase
    func storedFixedDynamicAndOptionalFields(): Unit {
        for (fixture in [gzipFixtureStored, gzipFixtureFixed, gzipFixtureOptional]) {
            for (chunk in [1, 2, 7, 4096]) {
                let source = GzipFixtureSource(gzipHex(fixture), chunk: chunk)
                let body = GzipBodyStream(source, limits: GzipLimits(inputBufferBytes: 7, maximumReadBytes: 3))
                @Expect(String.fromUtf8(gzipDrain(body)), "hello gzip")
                @Expect(body.integrityVerified)
                @Expect(body.memberCount, 1)
                @Expect(body.decodedBytes, 10)
                @Expect(body.encodedBytesRead, gzipHex(fixture).size)
                @Expect(source.isClosed())
                @Expect(body.maximumWorkBetweenChecks > 0 && body.maximumWorkBetweenChecks <= 512)
            }
        }
        let body = GzipBodyStream(GzipFixtureSource(gzipHex(gzipFixtureDynamic)))
        let decoded = gzipDrain(body)
        @Assert(decoded.size, 10000)
        let pattern = "abcde".toArray()
        for (index in 0..decoded.size) { @Assert(decoded[index], pattern[index % 5]) }
        @Expect(body.integrityVerified)
    }
    @TestCase
    func exactLimitsAndConcatenatedMembers(): Unit {
        let bytes = gzipHex(gzipFixtureFixed)
        let body = GzipBodyStream(GzipFixtureSource(bytes), limits: GzipLimits(maximumEncodedBytes: bytes.size, maximumDecodedBytes: 10))
        @Expect(String.fromUtf8(gzipDrain(body)), "hello gzip")
        @Expect(body.integrityVerified)
        @Expect(gzipFailure(bytes, GzipLimits(maximumDecodedBytes: 9)), GzipErrorCode.OutputLimit)
        @Expect(gzipFailure(bytes, GzipLimits(maximumEncodedBytes: bytes.size - 1)), GzipErrorCode.InputLimit)
        let joined = gzipHex(gzipFixtureFixed + gzipFixtureFixed)
        @Expect(gzipFailure(joined, GzipLimits()), GzipErrorCode.MemberLimit)
        @Expect(gzipFailure(joined, GzipLimits(maximumMembers: 2, maximumDecodedBytes: 19)), GzipErrorCode.OutputLimit)
        @Expect(gzipFailure(joined, GzipLimits(maximumMembers: 2, maximumBlocks: 1)), GzipErrorCode.BlockLimit)
        let multiple = GzipBodyStream(GzipFixtureSource(joined), limits: GzipLimits(maximumMembers: 2, maximumDecodedBytes: 20))
        @Expect(String.fromUtf8(gzipDrain(multiple)), "hello gziphello gzip")
        @Expect(multiple.memberCount, 2)
        @Expect(multiple.integrityVerified)
        @Expect(gzipFailure(gzipHex(gzipFixtureOptional), GzipLimits(maximumHeaderBytes: 29)), GzipErrorCode.HeaderLimit)
        let optional = GzipBodyStream(GzipFixtureSource(gzipHex(gzipFixtureOptional)), limits: GzipLimits(maximumHeaderBytes: 30))
        @Expect(String.fromUtf8(gzipDrain(optional)), "hello gzip")
    }
    @TestCase
    func emptyAndEveryTruncation(): Unit {
        let empty = GzipBodyStream(GzipFixtureSource(gzipHex(gzipFixtureEmpty)))
        @Expect(gzipDrain(empty).size, 0)
        @Expect(empty.integrityVerified)
        @Expect(gzipFailure(Array<Byte>(), GzipLimits()), GzipErrorCode.UnexpectedEof)
        for (fixture in [gzipFixtureStored, gzipFixtureFixed, gzipFixtureDynamic, gzipFixtureOptional]) {
            let bytes = gzipHex(fixture)
            for (cut in 0..bytes.size) {
                let truncated = Array<Byte>(cut, { index => bytes[index] })
                @Expect(gzipFailure(truncated, GzipLimits()), GzipErrorCode.UnexpectedEof)
            }
        }
    }
    @TestCase
    func checksumSizeFlagsStoredLengthAndTrailing(): Unit {
        let checksum = gzipHex(gzipFixtureFixed); checksum[checksum.size - 8] ^= 1
        @Expect(gzipFailure(checksum, GzipLimits()), GzipErrorCode.ChecksumMismatch)
        let size = gzipHex(gzipFixtureFixed); size[size.size - 4] ^= 1
        @Expect(gzipFailure(size, GzipLimits()), GzipErrorCode.SizeMismatch)
        let flags = gzipHex(gzipFixtureFixed); flags[3] = 32
        @Expect(gzipFailure(flags, GzipLimits()), GzipErrorCode.InvalidHeader)
        let nlen = gzipHex(gzipFixtureStored); nlen[13] ^= 1
        @Expect(gzipFailure(nlen, GzipLimits()), GzipErrorCode.InvalidDeflate)
        let fhcrc = gzipHex(gzipFixtureOptional); fhcrc[28] ^= 1
        @Expect(gzipFailure(fhcrc, GzipLimits()), GzipErrorCode.ChecksumMismatch)
        @Expect(gzipFailure(gzipHex(gzipFixtureFixed + "00"), GzipLimits()), GzipErrorCode.TrailingData)
        @Expect(gzipFailure(gzipHex(gzipFixtureFixed + "ffff"), GzipLimits(maximumMembers: 2)), GzipErrorCode.TrailingData)
    }
    @TestCase
    func largeOverlapBombAndBoundedWork(): Unit {
        let source = GzipFixtureSource(gzipHex(gzipFixtureBomb), chunk: 4096)
        let body = GzipBodyStream(source, limits: GzipLimits(maximumDecodedBytes: 131072))
        let decoded = gzipDrain(body)
        @Assert(decoded.size, 131072)
        for (byte in decoded) { @Assert(byte, b'A') }
        @Expect(body.integrityVerified)
        @Expect(body.maximumWorkBetweenChecks <= 512)
        @Expect(gzipFailure(gzipHex(gzipFixtureBomb), GzipLimits(maximumDecodedBytes: 131071)), GzipErrorCode.OutputLimit)
    }
    @TestCase
    func incrementalOwnershipAndUnverifiedClose(): Unit {
        let source = GzipFixtureSource(gzipHex(gzipFixtureBomb), chunk: 7)
        let body = GzipBodyStream(source, limits: GzipLimits(maximumReadBytes: 3))
        let buffer = Array<Byte>(100, repeat: 0)
        @Expect(body.read(buffer), 3)
        @Expect(body.decodedBytes, 3)
        @Expect(!body.integrityVerified)
        @Expect(!source.isClosed())
        @Expect(body.contentLength, None<Int64>)
        body.close(); body.close()
        @Expect(source.isClosed())
        @Expect(body.isClosed())
        @Expect(!body.integrityVerified)
        @Expect(body.decodedBytes, 3)
    }
    @TestCase
    func preReadDeadlineClosesSourceWithoutReading(): Unit {
        for (partial in [false, true]) {
            let clock = GzipCodecClock()
            let cancellation = CancellationSource()
            let source = GzipFixtureSource(gzipHex(gzipFixtureFixed))
            let body = GzipBodyStream(source, context: OperationContext(
                deadline: Some(Deadline.after(Duration.second, clock: clock)), cancellation: cancellation.token))
            if (partial) { @Expect(body.read(Array<Byte>(1, repeat: 0)), 1) }
            let reads = source.reads
            clock.advance(Duration.second)
            let error = @AssertThrows[NetworkException](body.read(Array<Byte>(1, repeat: 0)))
            match (error.code) { case NetworkErrorCode.TimedOut => (); case _ => @Fail("pre-read deadline must time out") }
            @Expect(source.reads, reads)
            @Expect(source.isClosed())
            @Expect(body.isClosed())
            @Expect(!body.integrityVerified)
            @Expect(body.decodedBytes, if (partial) { 1 } else { 0 })
            let closes = source.closes
            cancellation.cancel()
            body.close()
            @Expect(source.closes, closes)
        }
    }
    @TestCase
    func decoderFailureSurvivesThrowingSourceClose(): Unit {
        let bytes = gzipHex(gzipFixtureFixed)
        bytes[bytes.size - 8] ^= 1
        let source = GzipFixtureSource(bytes, throwsOnClose: true)
        let body = GzipBodyStream(source)
        let error = @AssertThrows[GzipException](gzipDrain(body))
        @Expect(error.code, GzipErrorCode.ChecksumMismatch)
        @Expect(body.decodedBytes, 10)
        @Expect(source.isClosed())
        @Expect(body.isClosed())
        @Expect(!body.integrityVerified)
        // Both the active close and terminal release encounter the throwing source.
        @Expect(source.closes, 2)
        let closed = @AssertThrows[GzipException](body.read(Array<Byte>(1, repeat: 0)))
        @Expect(closed.code, GzipErrorCode.Closed)
        body.close()
        @Expect(source.closes, 2)
    }
    @TestCase
    func publicCloseStillReportsSourceCloseFailure(): Unit {
        let source = GzipFixtureSource(gzipHex(gzipFixtureFixed), throwsOnClose: true)
        let body = GzipBodyStream(source)
        let _ = @AssertThrows[IllegalStateException](body.close())
        @Expect(body.isClosed())
        body.close()
        @Expect(source.closes, 2)
    }
    @TestCase
    func rejectedConcurrentReadDoesNotCloseOwnedRead(): Unit {
        let source = GzipFixtureSource(gzipHex(gzipFixtureFixed))
        let body = GzipBodyStream(source)
        source.beforeRead = { =>
            let error = @AssertThrows[GzipException](body.read(Array<Byte>(1, repeat: 0)))
            @Expect(error.code, GzipErrorCode.ConcurrentOperation)
            @Expect(!source.isClosed())
            @Expect(!body.isClosed())
        }
        @Expect(String.fromUtf8(gzipDrain(body)), "hello gzip")
        @Expect(body.integrityVerified)
    }
}
