package wirestack.net

import std.collection.ArrayList
import std.unittest.*
import std.unittest.testmacro.*
import wirestack as api

@Test
class DnsWireParserTest {
    @TestCase
    func decodesCompressedTargetsBinaryTxtSoaAndUnknownData(): Unit {
        let message = dnsTestHeader(0x1234u16, 0x8180u16, 1, 7, 0, 0)
        dnsTestAppendQuestion(message, "Example.COM", 1)
        dnsTestAppendRecord(message, [0xC0u8, 0x0Cu8], 5, [0xC0u8, 0x0Cu8])
        dnsTestAppendRecord(message, [0xC0u8, 0x0Cu8], 12, [0xC0u8, 0x0Cu8])
        dnsTestAppendRecord(message, [0xC0u8, 0x0Cu8], 15, [0u8, 10u8, 0xC0u8, 0x0Cu8])
        let srv = ArrayList<Byte>()
        for (value in [0u8, 1u8, 0u8, 2u8, 1u8, 187u8]) { srv.add(value) }
        dnsTestAppendName(srv, "Target.Example")
        dnsTestAppendRecord(message, [0xC0u8, 0x0Cu8], 33, srv.toArray())
        dnsTestAppendRecord(message, [0xC0u8, 0x0Cu8], 16, [3u8, 0u8, 255u8, 65u8, 0u8])
        let soa = ArrayList<Byte>()
        soa.add(0xC0u8)
        soa.add(0x0Cu8)
        soa.add(0xC0u8)
        soa.add(0x0Cu8)
        for (value in [1u32, 2u32, 3u32, 4u32, 30u32]) { dnsTestAppendU32(soa, value) }
        dnsTestAppendRecord(message, [0xC0u8, 0x0Cu8], 6, soa.toArray())
        dnsTestAppendRecord(message, [0xC0u8, 0x0Cu8], 65280, [0xDEu8, 0xADu8])

        let summary = DnsMessageParser().parse(message.toArray())
        @Expect(summary.transactionId, 0x1234u16)
        @Expect(summary.isResponse)
        @Expect(summary.opcode, 0)
        @Expect(summary.questions[0].name, "example.com")
        @Expect(summary.records.size, 7)
        @Expect(dnsTestTarget(summary.records[0]), "example.com")
        @Expect(dnsTestTarget(summary.records[1]), "example.com")
        @Expect(dnsTestTarget(summary.records[2]), "example.com")
        @Expect(dnsTestTarget(summary.records[3]), "target.example")
        @Expect(summary.records[4].data(), [3u8, 0u8, 255u8, 65u8, 0u8])
        match (summary.records[5].soaMinimum) {
            case Some(value) => @Expect(value, 30u32)
            case None => @Fail("SOA minimum was not decoded")
        }
        match (summary.records[6].recordType) {
            case DnsRecordType.Unknown(value) => @Expect(value, 65280)
            case _ => @Fail("unknown record type was not preserved")
        }
        @Expect(summary.records[6].data(), [0xDEu8, 0xADu8])
    }

    @TestCase
    func recordOrderMakesAnswerAuthorityAndAdditionalBoundariesExplicit(): Unit {
        let message = dnsTestHeader(7u16, 0x8180u16, 1, 1, 1, 1)
        dnsTestAppendQuestion(message, "ordered.example", 1)
        dnsTestAppendRecord(message, [0xC0u8, 0x0Cu8], 1, [1u8, 1u8, 1u8, 1u8])
        dnsTestAppendRecord(message, [0xC0u8, 0x0Cu8], 1, [2u8, 2u8, 2u8, 2u8])
        dnsTestAppendRecord(message, [0xC0u8, 0x0Cu8], 1, [3u8, 3u8, 3u8, 3u8])

        let summary = DnsMessageParser().parse(message.toArray())
        @Expect(summary.answerCount, 1)
        @Expect(summary.authorityCount, 1)
        @Expect(summary.additionalCount, 1)
        @Expect(summary.records[0].data(), [1u8, 1u8, 1u8, 1u8])
        @Expect(summary.records[summary.answerCount].data(), [2u8, 2u8, 2u8, 2u8])
        @Expect(summary.records[summary.answerCount + summary.authorityCount].data(), [3u8, 3u8, 3u8, 3u8])
    }

    @TestCase
    func summariesAndRecordsOwnParserAndConstructorInputs(): Unit {
        let message = dnsTestHeader(9u16, 0x8180u16, 1, 1, 0, 0)
        dnsTestAppendQuestion(message, "owned.example", 1)
        dnsTestAppendRecord(message, [0xC0u8, 0x0Cu8], 1, [10u8, 20u8, 30u8, 40u8])
        let wire = message.toArray()
        let summary = DnsMessageParser().parse(wire)

        wire[wire.size - 1] = 99u8
        let returnedData = summary.records[0].data()
        returnedData[0] = 99u8
        let supplied = [summary.records[0]]
        let constructed = DnsMessageSummary(9u16, 1, false, records: supplied)
        supplied[0] = DnsRecord("changed.example", DnsRecordType.A, 1u16, 0u32, [9u8, 9u8, 9u8, 9u8])

        @Expect(summary.records[0].name, "owned.example")
        @Expect(summary.records[0].data(), [10u8, 20u8, 30u8, 40u8])
        @Expect(constructed.records[0].name, "owned.example")
    }

    @TestCase
    func publicSummaryRejectsCountsBeyondWireAndCombinedRecordBounds(): Unit {
        let wire = dnsTestHeader(1u16, 0x8180u16, 1, 1, 0, 0)
        dnsTestAppendQuestion(wire, "limit.test", 1)
        dnsTestAppendRecord(wire, [0xC0u8, 0x0Cu8], 1, [127u8, 0u8, 0u8, 1u8])
        let parsed = DnsMessageParser().parse(wire.toArray())
        let questions = Array<DnsQuestion>(65536, repeat: parsed.questions[0])
        let records = Array<DnsRecord>(65536, repeat: parsed.records[0])
        @AssertThrows[IllegalArgumentException](
            DnsMessageSummary(1u16, 0, false, questionCount: 65536, questions: questions)
        )
        @AssertThrows[IllegalArgumentException](
            DnsMessageSummary(1u16, 65536, false, records: records)
        )
        @AssertThrows[IllegalArgumentException](
            DnsMessageSummary(1u16, 32768, false, authorityCount: 32768, records: records)
        )
        let bounded = DnsMessageSummary(1u16, 32768, false, authorityCount: 32767,
            records: Array<DnsRecord>(65535, repeat: parsed.records[0]))
        @Expect(bounded.records[65534].data(), [127u8, 0u8, 0u8, 1u8])
    }

    @TestCase
    func parserPreservesQuestionIdentityAndRejectsIncompleteRecords(): Unit {
        let wire = dnsTestHeader(0xBEEFu16, 0x0100u16, 1, 0, 0, 0)
        dnsTestAppendQuestion(wire, "_HTTPS._TCP.Example.COM", 33)
        let query = wire.toArray()
        let parsedQuery = DnsMessageParser().parse(query)
        @Expect(!parsedQuery.isResponse)
        @Expect(parsedQuery.opcode, 0)
        @Expect(parsedQuery.questionCount, 1)
        @Expect(parsedQuery.questions[0].name, "_https._tcp.example.com")
        @Expect(match (parsedQuery.questions[0].recordType) {
            case DnsRecordType.SRV => true
            case _ => false
        })
        @Expect(parsedQuery.questions[0].recordClass, 1u16)

        let opcodeMessage = dnsTestHeader(1u16, 0x9000u16, 0, 0, 0, 0)
        let opcodeSummary = DnsMessageParser().parse(opcodeMessage.toArray())
        @Expect(opcodeSummary.isResponse)
        @Expect(opcodeSummary.opcode, 2)

        let truncated = query.clone()
        truncated[2] = 0x83u8
        truncated[3] = 0x00u8
        truncated[6] = 0u8
        truncated[7] = 1u8
        @AssertThrows[api.ResolveException](DnsMessageParser().parse(truncated))
    }

    @TestCase
    func asciiNameProfileRejectsAmbiguousLabels(): Unit {
        for (invalid in ["a..b", "-bad.example", "bad-.example", "bad label", "a/b", "é.example"]) {
            let wire = dnsTestHeader(1u16, 0x8180u16, 1, 0, 0, 0)
            dnsTestAppendQuestion(wire, invalid, 1)
            @AssertThrows[api.ResolveException](DnsMessageParser().parse(wire.toArray()))
        }

        let message = dnsTestHeader(3u16, 0x8180u16, 1, 0, 0, 0)
        message.add(3u8)
        message.add(b'a')
        message.add(b'.')
        message.add(b'b')
        message.add(0u8)
        dnsTestAppendU16(message, 1)
        dnsTestAppendU16(message, 1)
        @AssertThrows[api.ResolveException](DnsMessageParser().parse(message.toArray()))
    }

    @TestCase
    func compressionLoopsForwardPointersAndOutOfRangePointersAreRejected(): Unit {
        for (name in [
            [0xC0u8, 0x0Cu8],
            [0xC0u8, 0x0Eu8],
            [0xFFu8, 0xFFu8]
        ]) {
            let message = dnsTestHeader(1u16, 0x8180u16, 1, 0, 0, 0)
            for (value in name) { message.add(value) }
            @AssertThrows[api.ResolveException](DnsMessageParser().parse(message.toArray()))
        }
    }

    @TestCase
    func expandedNameAndSectionCountsRespectConfiguredBounds(): Unit {
        let question = dnsTestHeader(1u16, 0x8180u16, 1, 0, 0, 0)
        dnsTestAppendQuestion(question, "abcd", 1)
        @AssertThrows[api.ResolveException](
            DnsMessageParser(limits: DnsParserLimits(maximumNameBytes: 3)).parse(question.toArray())
        )

        let tooManyQuestions = dnsTestHeader(1u16, 0x8180u16, 2, 0, 0, 0)
        @AssertThrows[api.ResolveException](
            DnsMessageParser(limits: DnsParserLimits(maximumQuestions: 1)).parse(tooManyQuestions.toArray())
        )
        let tooManyRecords = dnsTestHeader(1u16, 0x8180u16, 0, 2, 0, 0)
        @AssertThrows[api.ResolveException](
            DnsMessageParser(limits: DnsParserLimits(maximumRecords: 1)).parse(tooManyRecords.toArray())
        )

        let chained = dnsTestHeader(1u16, 0x8180u16, 1, 2, 0, 0)
        dnsTestAppendQuestion(chained, "chain.example", 1)
        let firstOwner = chained.size
        dnsTestAppendRecord(chained, [0xC0u8, 0x0Cu8], 65000, Array<Byte>())
        dnsTestAppendRecord(chained, dnsTestPointer(firstOwner), 65000, Array<Byte>())
        @AssertThrows[api.ResolveException](
            DnsMessageParser(limits: DnsParserLimits(maximumIndirections: 1)).parse(chained.toArray())
        )
    }

    @TestCase
    func completeParserRejectsTrailingAndTruncatedSectionBytes(): Unit {
        let trailing = dnsTestHeader(1u16, 0x8180u16, 0, 0, 0, 0)
        trailing.add(0u8)
        @AssertThrows[api.ResolveException](DnsMessageParser().parse(trailing.toArray()))

        let reservedHeader = dnsTestHeader(1u16, 0x8040u16, 0, 0, 0, 0)
        @AssertThrows[api.ResolveException](DnsMessageParser().parse(reservedHeader.toArray()))

        let shortQuestion = dnsTestHeader(1u16, 0x8180u16, 1, 0, 0, 0)
        shortQuestion.add(0u8)
        shortQuestion.add(0u8)
        @AssertThrows[api.ResolveException](DnsMessageParser().parse(shortQuestion.toArray()))

        let shortRecord = dnsTestHeader(1u16, 0x8180u16, 0, 1, 0, 0)
        shortRecord.add(0u8)
        dnsTestAppendU16(shortRecord, 1)
        dnsTestAppendU16(shortRecord, 1)
        dnsTestAppendU32(shortRecord, 1u32)
        dnsTestAppendU16(shortRecord, 4)
        shortRecord.add(1u8)
        shortRecord.add(2u8)
        @AssertThrows[api.ResolveException](DnsMessageParser().parse(shortRecord.toArray()))
    }

    @TestCase
    func typedRdataLengthsAndTxtSegmentsAreExact(): Unit {
        for ((typeCode, data) in [
            (1, [1u8, 2u8, 3u8]),
            (28, Array<Byte>(15, repeat: 0u8)),
            (16, [4u8, 1u8, 2u8]),
            (16, Array<Byte>())
        ]) {
            let message = dnsTestHeader(1u16, 0x8180u16, 0, 1, 0, 0)
            dnsTestAppendRecord(message, [0u8], typeCode, data)
            @AssertThrows[api.ResolveException](DnsMessageParser().parse(message.toArray()))
        }
    }

    @TestCase
    func compressedRdataNamesCannotConsumeNeighboringRecordBytes(): Unit {
        let extra = dnsTestHeader(1u16, 0x8180u16, 1, 1, 0, 0)
        dnsTestAppendQuestion(extra, "escape.example", 1)
        dnsTestAppendRecord(extra, [0xC0u8, 0x0Cu8], 5, [0xC0u8, 0x0Cu8, 0u8])
        @AssertThrows[api.ResolveException](DnsMessageParser().parse(extra.toArray()))

        let escape = dnsTestHeader(1u16, 0x8180u16, 1, 2, 0, 0)
        dnsTestAppendQuestion(escape, "escape.example", 1)
        dnsTestAppendRecord(escape, [0xC0u8, 0x0Cu8], 5, [1u8, b'a'])
        dnsTestAppendRecord(escape, [0u8], 1, [1u8, 2u8, 3u8, 4u8])
        @AssertThrows[api.ResolveException](DnsMessageParser().parse(escape.toArray()))
    }

    @TestCase
    func srvTargetCompressionIsRejectedEvenWhenPointerIsInBounds(): Unit {
        let message = dnsTestHeader(1u16, 0x8180u16, 1, 1, 0, 0)
        dnsTestAppendQuestion(message, "_svc._tcp.example", 33)
        dnsTestAppendRecord(message, [0xC0u8, 0x0Cu8], 33,
            [0u8, 1u8, 0u8, 2u8, 0u8, 80u8, 0xC0u8, 0x0Cu8])
        @AssertThrows[api.ResolveException](DnsMessageParser().parse(message.toArray()))
    }

    @TestCase
    func summaryConstructorRejectsSectionMetadataThatCouldBlurBoundaries(): Unit {
        @AssertThrows[IllegalArgumentException](DnsMessageSummary(
            1u16,
            1,
            false,
            questionCount: 0,
            records: Array<DnsRecord>()
        ))
    }

    @TestCase
    func additionalOwnerMayReferenceAuthorityNameserverTarget(): Unit {
        let message = dnsTestHeader(0x1234u16, 0x8180u16, 1, 1, 1, 1)
        dnsTestAppendQuestion(message, "example.test", 1)
        dnsTestAppendRecord(message, [0xC0u8, 0x0Cu8], 1, [192u8, 0u8, 2u8, 1u8])
        let nameserverOffset = message.size + 12
        dnsTestAppendRecord(message, [0xC0u8, 0x0Cu8], 2, [2u8, b'n', b's', 0xC0u8, 0x0Cu8])
        dnsTestAppendRecord(message, dnsTestPointer(nameserverOffset), 1, [192u8, 0u8, 2u8, 53u8])
        let summary = DnsMessageParser().parse(message.toArray())
        @Expect(summary.records[0].data(), [192u8, 0u8, 2u8, 1u8])
        @Expect(summary.records[2].name, "ns.example.test")
        @Expect(summary.records[2].data(), [192u8, 0u8, 2u8, 53u8])
    }

    @TestCase
    func additionalOwnerMayReferenceSecondLegacyMailboxName(): Unit {
        let message = dnsTestHeader(1u16, 0x8180u16, 1, 0, 1, 1)
        dnsTestAppendQuestion(message, "example.test", 1)
        let mailboxOffset = message.size + 14
        let data = [0xC0u8, 0x0Cu8, 3u8, b'e', b'r', b'r', 0xC0u8, 0x0Cu8]
        dnsTestAppendRecord(message, [0xC0u8, 0x0Cu8], 14, data)
        dnsTestAppendRecord(message, dnsTestPointer(mailboxOffset), 1, [192u8, 0u8, 2u8, 9u8])
        let summary = DnsMessageParser().parse(message.toArray())
        @Expect(summary.records[0].data(), data)
        @Expect(summary.records[1].name, "err.example.test")
        @Expect(summary.records[1].data(), [192u8, 0u8, 2u8, 9u8])

        let missingMailbox = dnsTestHeader(1u16, 0x8180u16, 1, 1, 0, 0)
        dnsTestAppendQuestion(missingMailbox, "example.test", 14)
        dnsTestAppendRecord(missingMailbox, [0xC0u8, 0x0Cu8], 14, [0xC0u8, 0x0Cu8])
        @AssertThrows[api.ResolveException](DnsMessageParser().parse(missingMailbox.toArray()))
    }
}

/** Deterministic mutation fuzzing with structural and ownership oracles. */
@Test
class DnsWireFuzzTest {
    @TestCase
    func wireMutationsRejectMalformedMessagesOrRetainOwnedSections(): Unit {
        let soa = ArrayList<Byte>()
        for (value in [0xC0u8, 0x0Cu8, 0xC0u8, 0x0Cu8]) { soa.add(value) }
        for (value in [1u32, 2u32, 3u32, 4u32, 30u32]) { dnsTestAppendU32(soa, value) }
        let seeds = ArrayList<Array<Byte>>()
        for ((kind, data) in [
            (1, [192u8, 0u8, 2u8, 1u8]),
            (28, Array<Byte>(16, repeat: 1u8)),
            (5, [0xC0u8, 0x0Cu8]),
            (12, [0xC0u8, 0x0Cu8]),
            (15, [0u8, 10u8, 0xC0u8, 0x0Cu8]),
            (33, [0u8, 1u8, 0u8, 2u8, 0u8, 80u8, 1u8, b'a', 0u8]),
            (16, [3u8, 0u8, 255u8, 65u8, 0u8]),
            (6, soa.toArray()),
            (65280, [0xC0u8, 0xFFu8, 0u8, 255u8]),
            (2, [2u8, b'n', b's', 0xC0u8, 0x0Cu8]),
            (14, [0xC0u8, 0x0Cu8, 3u8, b'e', b'r', b'r', 0xC0u8, 0x0Cu8])
        ]) {
            let message = dnsTestHeader(8004u16, 0x8180u16, 1, 1, 0, 0)
            dnsTestAppendQuestion(message, "fuzz.example", kind)
            dnsTestAppendRecord(message, [0xC0u8, 0x0Cu8], kind, data)
            seeds.add(message.toArray())
        }
        let sections = dnsTestHeader(8004u16, 0x8180u16, 1, 1, 1, 1)
        dnsTestAppendQuestion(sections, "fuzz.example", 1)
        dnsTestAppendRecord(sections, [0xC0u8, 0x0Cu8], 1, [192u8, 0u8, 2u8, 1u8])
        let targetOffset = sections.size + 12
        dnsTestAppendRecord(sections, [0xC0u8, 0x0Cu8], 2, [2u8, b'n', b's', 0xC0u8, 0x0Cu8])
        dnsTestAppendRecord(sections, dnsTestPointer(targetOffset), 28, Array<Byte>(16, repeat: 1u8))
        seeds.add(sections.toArray())

        let replacements = [0u8, 1u8, 12u8, 63u8, 64u8, 127u8, 128u8, 191u8, 192u8, 255u8]
        var executions: Int64 = 0
        var accepted: Int64 = 0
        var rejected: Int64 = 0
        var random: UInt64 = 8004u64
        for (seed in seeds) {
            @Assert(dnsFuzzAcceptsOwnedMessage(seed.clone(), executions))
            for (index in 0..seed.size) {
                for (replacement in replacements) {
                    let mutated = seed.clone()
                    mutated[index] = replacement
                    executions++
                    if (dnsFuzzAcceptsOwnedMessage(mutated, executions)) { accepted++ } else { rejected++ }
                }
                executions++
                @Assert(!dnsFuzzAcceptsOwnedMessage(seed.clone(0..index), executions))
                rejected++
            }
            let trailing = ArrayList<Byte>()
            for (value in seed) { trailing.add(value) }
            trailing.add(0u8)
            executions++
            @Assert(!dnsFuzzAcceptsOwnedMessage(trailing.toArray(), executions))
            rejected++
            for (_ in 0..128) {
                let mutated = seed.clone()
                for (_ in 0..4) {
                    random = (random * 1664525u64 + 1013904223u64) & 0xFFFFFFFFu64
                    let index = Int64(random % UInt64(mutated.size))
                    random = (random * 1664525u64 + 1013904223u64) & 0xFFFFFFFFu64
                    mutated[index] = UInt8(random & 0xFFu64)
                }
                executions++
                if (dnsFuzzAcceptsOwnedMessage(mutated, executions)) { accepted++ } else { rejected++ }
            }
        }
        println("M8004_FUZZ target=dns-wire seed=8004 corpus=${seeds.size} " +
            "iterations=${executions} accepted=${accepted} rejected=${rejected} decision=PASS")
    }
}

private func dnsFuzzAcceptsOwnedMessage(wire: Array<Byte>, caseId: Int64): Bool {
    let parsed = try {
        Some(DnsMessageParser().parse(wire))
    } catch (_: api.ResolveException) {
        None<DnsMessageSummary>
    } catch (error: Exception) {
        println("M8004_FUZZ unexpected-error case=${caseId}")
        throw error
    }
    match (parsed) {
        case None => false
        case Some(summary) =>
            let records = summary.records
            @Assert(records.size, summary.answerCount + summary.authorityCount + summary.additionalCount)
            let snapshots = ArrayList<Array<Byte>>()
            for (record in records) { snapshots.add(record.data()) }
            for (index in 0..wire.size) { wire[index] = 0u8 }
            for (index in 0..records.size) {
                let returned = records[index].data()
                if (!returned.isEmpty()) { returned[0] = returned[0] ^ 0xFFu8 }
                @Assert(records[index].data(), snapshots[index])
            }
            true
    }
}

private func dnsTestHeader(
    id: UInt16,
    flags: UInt16,
    questions: Int64,
    answers: Int64,
    authorities: Int64,
    additionals: Int64
): ArrayList<Byte> {
    let output = ArrayList<Byte>()
    dnsTestAppendU16(output, Int64(id))
    dnsTestAppendU16(output, Int64(flags))
    dnsTestAppendU16(output, questions)
    dnsTestAppendU16(output, answers)
    dnsTestAppendU16(output, authorities)
    dnsTestAppendU16(output, additionals)
    output
}

private func dnsTestAppendQuestion(output: ArrayList<Byte>, name: String, typeCode: Int64): Unit {
    dnsTestAppendName(output, name)
    dnsTestAppendU16(output, typeCode)
    dnsTestAppendU16(output, 1)
}

private func dnsTestAppendRecord(
    output: ArrayList<Byte>,
    owner: Array<Byte>,
    typeCode: Int64,
    data: Array<Byte>
): Unit {
    for (value in owner) { output.add(value) }
    dnsTestAppendU16(output, typeCode)
    dnsTestAppendU16(output, 1)
    dnsTestAppendU32(output, 60u32)
    dnsTestAppendU16(output, data.size)
    for (value in data) { output.add(value) }
}

private func dnsTestAppendName(output: ArrayList<Byte>, name: String): Unit {
    if (name == ".") {
        output.add(0u8)
        return
    }
    for (label in name.split(".")) {
        let bytes = label.toArray()
        output.add(UInt8(UInt64(bytes.size)))
        for (value in bytes) { output.add(value) }
    }
    output.add(0u8)
}

private func dnsTestAppendU16(output: ArrayList<Byte>, value: Int64): Unit {
    output.add(UInt8(UInt64((value >> 8) & 0xFF)))
    output.add(UInt8(UInt64(value & 0xFF)))
}

private func dnsTestAppendU32(output: ArrayList<Byte>, value: UInt32): Unit {
    output.add(UInt8(UInt64((value >> 24) & 0xFFu32)))
    output.add(UInt8(UInt64((value >> 16) & 0xFFu32)))
    output.add(UInt8(UInt64((value >> 8) & 0xFFu32)))
    output.add(UInt8(UInt64(value & 0xFFu32)))
}

private func dnsTestPointer(offset: Int64): Array<Byte> {
    [
        UInt8(UInt64(0xC0 | ((offset >> 8) & 0x3F))),
        UInt8(UInt64(offset & 0xFF))
    ]
}

private func dnsTestTarget(record: DnsRecord): String {
    match (record.targetName) {
        case Some(value) => value
        case None => throw Exception("record target was not decoded")
    }
}
