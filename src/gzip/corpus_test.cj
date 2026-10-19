package wirestack.gzip
import std.unittest.*
import std.unittest.testmacro.*

// RFC1951 bit-level fixtures were independently rejected by Python zlib.
@Test
class GzipMalformedCorpusTest {
    @TestCase
    func invalidTreesReservedSymbolsAndHistory(): Unit {
        let corpus: Array<String> = [
            "1f8b08000000000000ff070000000000000000", // reserved block
            "1f8b08000000000000ff1b030000000000000000", // reserved literal
            "1f8b08000000000000ff03020000000000000000", // before history
            "1f8b08000000000000ff73043e0000000000000000", // reserved distance
            "1f8b08000000000000ff050092040000000000000000", // oversubscribed
            "1f8b08000000000000ff050004000000000000000000", // incomplete
            "1f8b08000000000000ff05c0010400000000100000000000000000000000000000000000000000000000000000000000000000000000000000000000", // no end code
            "1f8b08000000000000ff050082000000000000000000", // repeat without previous
            "1f8b08000000000000ff050082e0ff1f0000000000000000", // repeat overflow
            "1f8b08000000000000ff05800104000000400000000000000000000000000000000000000000000000000000000000000000020000000000000000", // incomplete literal
        ]
        for (fixture in corpus) {
            @Expect(gzipFailure(gzipHex(fixture), GzipLimits()), GzipErrorCode.InvalidDeflate)
        }
    }
    @TestCase
    func legalSingleSymbolAndEmptyDistanceTree(): Unit {
        let body = GzipBodyStream(GzipFixtureSource(gzipHex("1f8b08000000000000ff05c0010400000000100000000000000000000000000000000000000000000000000000000000000080000000000000000000")))
        @Expect(gzipDrain(body).size, 0)
        @Expect(body.integrityVerified)
    }
    @TestCase
    func emptyBlocksConsumeCumulativeBlockBudget(): Unit {
        // Two stored blocks, first non-final and second final, both LEN=0.
        let bytes = gzipHex("1f8b08000000000000ff000000ffff010000ffff0000000000000000")
        @Expect(gzipFailure(bytes, GzipLimits(maximumBlocks: 1)), GzipErrorCode.BlockLimit)
        let body = GzipBodyStream(GzipFixtureSource(bytes), limits: GzipLimits(maximumBlocks: 2))
        @Expect(gzipDrain(body).size, 0)
        @Expect(body.integrityVerified)
    }
    @TestCase
    func nextMemberCannotReferencePreviousHistory(): Unit {
        let bytes = gzipHex(gzipFixtureFixed + "1f8b08000000000000ff03020000000000000000")
        @Expect(gzipFailure(bytes, GzipLimits(maximumMembers: 2)), GzipErrorCode.InvalidDeflate)
    }
}
