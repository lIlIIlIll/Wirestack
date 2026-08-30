package yjson

import std.collection.*
import std.math.numeric.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class YJsonTemporalNumberFastTest {
    private func bytes(text: String): Array<Byte> {
        unsafe {
            text.rawData()
        }
    }

    private func compactTemporalStatsText(ratios: String): String {
        "{\"createdAt\":\"2024-06-20T14:42:33+08:00\"," +
            "\"totalEvents\":123456789012345678901234567890," +
            "\"averageLatency\":12.375," +
            "\"checkpoints\":[\"2024-06-20T14:42:33+08:00\",\"2024-06-20T15:12:33+08:00\"]," +
            "\"ratios\":" + ratios + "}"
    }

    private func assertTemporalStatsBenchmarkValue(value: TemporalStats): Unit {
        @Expect(value.createdAt, DateTime.parse("2024-06-20T14:42:33+08:00", DateTimeFormat.RFC3339))
        @Expect(value.totalEvents, BigInt.parse("123456789012345678901234567890"))
        @Expect(value.averageLatency, Decimal.parse("12.375"))
        @Expect(value.checkpoints.size, 2)
        @Expect(value.checkpoints[0], DateTime.parse("2024-06-20T14:42:33+08:00", DateTimeFormat.RFC3339))
        @Expect(value.checkpoints[1], DateTime.parse("2024-06-20T15:12:33+08:00", DateTimeFormat.RFC3339))
        @Expect(value.ratios.size, 2)
        @Expect(value.ratios["p50"], Decimal.parse("12.5"))
        @Expect(value.ratios["p99"], Decimal.parse("98.25"))
    }

    private func stdlibDateTimeParseThrows(text: String): Bool {
        try {
            let _ = DateTime.parse(text, DateTimeFormat.RFC3339)
            return false
        } catch (_: Exception) {
            return true
        }
    }

    private func datetimeDecodeThrows(text: String): Bool {
        try {
            let _ = YJson.decodeStringWith(DateTimeJson, text)
            return false
        } catch (_: Exception) {
            return true
        }
    }

    private func assertRfc3339DecodeMatchesStdlib(text: String): Unit {
        let expected = DateTime.parse(text, DateTimeFormat.RFC3339)
        @Expect(jsonFastParseRfc3339DateTime(text), expected)
        @Expect(YJson.decodeStringWith(DateTimeJson, "\"" + text + "\""), expected)

        let reader = JsonFastReader(bytes("\"" + text + "\""))
        @Expect(jsonFastReadRfc3339DateTime(reader), expected)
        reader.expectEnd()
    }

    private func assertRfc3339FallbackMatchesStdlib(text: String): Unit {
        let expected: Option<DateTime> = try {
            Some(DateTime.parse(text, DateTimeFormat.RFC3339))
        } catch (_: Exception) {
            None<DateTime>
        }
        match (expected) {
            case Some(value) =>
                @Expect(jsonFastParseRfc3339DateTime(text), value)
                let reader = JsonFastReader(bytes("\"" + text + "\""))
                @Expect(jsonFastReadRfc3339DateTime(reader), value)
            case None =>
                @AssertThrows[Exception](jsonFastParseRfc3339DateTime(text))
                let reader = JsonFastReader(bytes("\"" + text + "\""))
                @AssertThrows[Exception](jsonFastReadRfc3339DateTime(reader))
        }
    }

    @TestCase
    func datetimeFastPathParsesBenchmarkOffsetShape(): Unit {
        let text = "\"2024-06-20T14:42:33+08:00\""
        let decoded = YJson.decodeStringWith(DateTimeJson, text)
        @Expect(decoded, DateTime.parse("2024-06-20T14:42:33+08:00", DateTimeFormat.RFC3339))
        @Expect(YJson.encodeStringWith(DateTimeJson, decoded), text)
    }

    @TestCase
    func datetimeFastPathKeepsStdlibResults(): Unit {
        let createdAtText = "2024-06-20T14:42:33+08:00"
        let checkpointText = "2024-06-20T15:12:33+08:00"
        let createdAt = YJson.decodeStringWith(DateTimeJson, "\"" + createdAtText + "\"")
        let checkpoint = YJson.decodeStringWith(DateTimeJson, "\"" + checkpointText + "\"")

        @Expect(createdAt, DateTime.parse(createdAtText, DateTimeFormat.RFC3339))
        @Expect(checkpoint, DateTime.parse(checkpointText, DateTimeFormat.RFC3339))
        @Expect(YJson.encodeStringWith(DateTimeJson, createdAt), "\"" + createdAtText + "\"")
        @Expect(YJson.encodeStringWith(DateTimeJson, checkpoint), "\"" + checkpointText + "\"")
    }

    @TestCase
    func datetimeFixedOffsetCacheKeepsStdlibEquivalence(): Unit {
        assertRfc3339DecodeMatchesStdlib("1970-01-01T00:00:00Z")
        assertRfc3339DecodeMatchesStdlib("2024-02-29T23:59:59+08:00")
        assertRfc3339DecodeMatchesStdlib("2000-02-29T23:59:59+08:00")
        assertRfc3339DecodeMatchesStdlib("2032-01-02T03:04:05Z")
        assertRfc3339DecodeMatchesStdlib("2032-01-02T03:04:05+00:00")
        assertRfc3339DecodeMatchesStdlib("2032-01-02T04:04:05+01:00")
        assertRfc3339DecodeMatchesStdlib("2032-01-02T08:34:05+05:30")
        assertRfc3339DecodeMatchesStdlib("2032-01-01T22:34:05-04:30")
        assertRfc3339DecodeMatchesStdlib("2024-06-20T14:42:33+24:00")
    }

    @TestCase
    func datetimeFastPathCoversCalendarAndFallbackDecisionMatrix(): Unit {
        let monthDays: Array<Int64> = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        for (month in 1..13) {
            let monthText = if (month < 10) { "0${month}" } else { "${month}" }
            let day = monthDays[month - 1]
            let dayText = if (day < 10) { "0${day}" } else { "${day}" }
            assertRfc3339DecodeMatchesStdlib("2023-${monthText}-${dayText}T12:34:56Z")
        }
        assertRfc3339DecodeMatchesStdlib("1900-02-28T12:34:56Z")
        assertRfc3339DecodeMatchesStdlib("2000-02-29T12:34:56Z")

        // Each mutation reaches a distinct fast-path guard before the stdlib
        // fallback rejects it. Run both String and raw-token implementations.
        let invalid = [
            "2024-01-01T00:00:00", "2024/01-01T00:00:00Z",
            "2024-01/01T00:00:00Z", "2024-01-01 00:00:00Z",
            "2024-01-01T00-00:00Z", "2024-01-01T00:00-00Z",
            "0000-01-01T00:00:00Z", "x024-01-01T00:00:00Z",
            "2024-x1-01T00:00:00Z", "2024-00-01T00:00:00Z",
            "2024-13-01T00:00:00Z", "2024-01-x1T00:00:00Z",
            "2024-01-00T00:00:00Z", "2024-01-32T00:00:00Z",
            "2023-02-29T00:00:00Z", "2024-01-01Tx0:00:00Z",
            "2024-01-01T24:00:00Z", "2024-01-01T00:x0:00Z",
            "2024-01-01T00:60:00Z", "2024-01-01T00:00:x0Z",
            "2024-01-01T00:00:60Z", "2024-01-01T00:00:00X",
            "2024-01-01T00:00:00*08:00", "2024-01-01T00:00:00+08-00",
            "2024-01-01T00:00:00+x8:00", "2024-01-01T00:00:00+24:00",
            "2024-01-01T00:00:00+08:x0", "2024-01-01T00:00:00+08:60"
        ]
        for (text in invalid) {
            assertRfc3339FallbackMatchesStdlib(text)
        }
    }

    @TestCase
    func datetimeFastPathParsesDifferentOffsets(): Unit {
        let east = YJson.decodeStringWith(DateTimeJson, "\"2024-06-20T14:42:33+05:30\"")
        let west = YJson.decodeStringWith(DateTimeJson, "\"2024-06-20T01:12:33-04:00\"")
        let utc = YJson.decodeStringWith(DateTimeJson, "\"2024-06-20T06:42:33Z\"")

        @Expect(east, DateTime.parse("2024-06-20T14:42:33+05:30", DateTimeFormat.RFC3339))
        @Expect(west, DateTime.parse("2024-06-20T01:12:33-04:00", DateTimeFormat.RFC3339))
        @Expect(utc, DateTime.parse("2024-06-20T06:42:33Z", DateTimeFormat.RFC3339))
        @Expect(YJson.encodeStringWith(DateTimeJson, utc), "\"2024-06-20T06:42:33Z\"")
    }

    @TestCase
    func datetimeReaderParsesUncachedValueAndKeepsFallback(): Unit {
        let reader = JsonFastReader(bytes("  \"2024-06-21T01:02:03+05:45\"  "))
        @Expect(jsonFastReadRfc3339DateTime(reader), DateTime.parse("2024-06-21T01:02:03+05:45", DateTimeFormat.RFC3339))
        reader.expectEnd()

        let fractionalReader = JsonFastReader(bytes("\"2024-06-20T14:42:33.123+08:00\""))
        try {
            let _ = jsonFastReadRfc3339DateTime(fractionalReader)
            @Expect(false)
        } catch (_: Exception) {
            @Expect(true)
        }
    }

    @TestCase
    func datetimeReaderCacheKeepsRepeatedFixedOffsetSemantics(): Unit {
        let reader = JsonFastReader(bytes(
            "[\"2024-06-20T14:42:33+08:00\",\"2024-06-20T14:42:33+08:00\",\"2024-06-20T01:12:33-04:00\"]"
        ))
        let values = jsonFastReadArrayListRfc3339DateTime(reader)
        reader.expectEnd()

        @Expect(values.size, 3)
        @Expect(values[0], DateTime.parse("2024-06-20T14:42:33+08:00", DateTimeFormat.RFC3339))
        @Expect(values[1], DateTime.parse("2024-06-20T14:42:33+08:00", DateTimeFormat.RFC3339))
        @Expect(values[2], DateTime.parse("2024-06-20T01:12:33-04:00", DateTimeFormat.RFC3339))
    }

    @TestCase
    func datetimeFallbackRejectsUnsupportedFractionalSecondsLikeStdlib(): Unit {
        let value = "2024-06-20T14:42:33.123+08:00"
        @Expect(stdlibDateTimeParseThrows(value))
        @Expect(datetimeDecodeThrows("\"" + value + "\""))
    }

    @TestCase
    func datetimeFastPathRejectsInvalidCalendarDateLikeStdlib(): Unit {
        let value = "2023-02-29T14:42:33+08:00"
        @Expect(stdlibDateTimeParseThrows(value))
        @Expect(datetimeDecodeThrows("\"" + value + "\""))

        let centuryNonLeap = "1900-02-29T14:42:33+08:00"
        @Expect(stdlibDateTimeParseThrows(centuryNonLeap))
        @Expect(datetimeDecodeThrows("\"" + centuryNonLeap + "\""))
    }

    @TestCase
    func datetimeFastPathRejectsInvalidOffsetLikeStdlib(): Unit {
        let value = "2024-06-20T14:42:33+08:6x"
        @Expect(stdlibDateTimeParseThrows(value))
        @Expect(datetimeDecodeThrows("\"" + value + "\""))
    }

    @TestCase
    func bigIntFastPathPreservesPositiveNegativeAndFallbackValues(): Unit {
        let positive = YJson.decodeStringWith(BigIntJson, "123456789012345678901234567890")
        let negative = YJson.decodeStringWith(BigIntJson, "-123456789012345678901234567890")
        let fallback = YJson.decodeStringWith(BigIntJson, "42")

        @Expect(positive, BigInt.parse("123456789012345678901234567890"))
        @Expect(negative, BigInt.parse("-123456789012345678901234567890"))
        @Expect(fallback, BigInt.parse("42"))
        @Expect(YJson.encodeStringWith(BigIntJson, positive), "123456789012345678901234567890")
        @Expect(YJson.encodeStringWith(BigIntJson, negative), "-123456789012345678901234567890")
    }

    @TestCase
    func bigIntReaderFallsBackForUncachedValues(): Unit {
        let smallReader = JsonFastReader(bytes("  -42  "))
        @Expect(jsonFastReadBigInt(smallReader), BigInt.parse("-42"))
        smallReader.expectEnd()

        let largeReader = JsonFastReader(bytes("922337203685477580899"))
        @Expect(jsonFastReadBigInt(largeReader), BigInt.parse("922337203685477580899"))
        largeReader.expectEnd()
    }

    @TestCase
    func decimalFastPathPreservesPositiveNegativeAndSmallValues(): Unit {
        let average = YJson.decodeStringWith(DecimalJson, "12.375")
        let p99 = YJson.decodeStringWith(DecimalJson, "98.25")
        let negative = YJson.decodeStringWith(DecimalJson, "-12.5")
        let small = YJson.decodeStringWith(DecimalJson, "0.001")

        @Expect(average, Decimal.parse("12.375"))
        @Expect(p99, Decimal.parse("98.25"))
        @Expect(negative, Decimal.parse("-12.5"))
        @Expect(small, Decimal.parse("0.001"))
        @Expect(YJson.encodeStringWith(DecimalJson, average), "12.375")
        @Expect(YJson.encodeStringWith(DecimalJson, p99), "98.25")
        @Expect(YJson.encodeStringWith(DecimalJson, negative), "-12.5")
        @Expect(YJson.encodeStringWith(DecimalJson, small), "0.001")
    }

    @TestCase
    func decimalReaderFallsBackForSimpleAndExponentValues(): Unit {
        let scaleReader = JsonFastReader(bytes("12.50"))
        let scaleValue = jsonFastReadDecimal(scaleReader)
        @Expect(scaleValue, Decimal.parse("12.50"))
        @Expect(scaleValue.toString(), "12.50")
        scaleReader.expectEnd()

        let exponentReader = JsonFastReader(bytes("1.25e2"))
        @Expect(jsonFastReadDecimal(exponentReader), Decimal.parse("1.25e2"))
        exponentReader.expectEnd()
    }

    @TestCase
    func readerHelpersConsumeRawTokensThroughFastPath(): Unit {
        let createdAtReader = JsonFastReader(bytes("  \"2024-06-20T14:42:33+08:00\"  "))
        @Expect(jsonFastReadRfc3339DateTime(createdAtReader), DateTime.parse("2024-06-20T14:42:33+08:00", DateTimeFormat.RFC3339))
        createdAtReader.expectEnd()

        let totalEventsReader = JsonFastReader(bytes("  123456789012345678901234567890  "))
        @Expect(jsonFastReadBigInt(totalEventsReader), BigInt.parse("123456789012345678901234567890"))
        totalEventsReader.expectEnd()

        let averageReader = JsonFastReader(bytes("  12.375  "))
        @Expect(jsonFastReadDecimal(averageReader), Decimal.parse("12.375"))
        averageReader.expectEnd()
    }

    @TestCase
    func rawTokenReaderApiExposesGenericCompactTokens(): Unit {
        let dateReader = JsonFastReader(bytes("  \"2031-01-02T03:04:05Z\"  "))
        @Expect(dateReader.tryReadRawAsciiStringToken())
        @Expect(dateReader.currentRawTokenSize(), 20)
        @Expect(dateReader.currentRawTokenFourDigits(0), 2031)
        @Expect(dateReader.currentRawTokenTwoDigits(5), 1)
        @Expect(dateReader.currentRawTokenByte(10), b'T')
        @Expect(dateReader.currentRawTokenAsciiString(), "2031-01-02T03:04:05Z")
        dateReader.expectEnd()

        let sizedDateReader = JsonFastReader(bytes("  \"2031-01-02T03:04:05+08:00\"  "))
        @Expect(sizedDateReader.tryReadRawAsciiStringTokenSize2(20, 25))
        @Expect(sizedDateReader.currentRawTokenSize(), 25)
        @Expect(sizedDateReader.currentRawTokenByte(19), b'+')
        @Expect(sizedDateReader.currentRawTokenAsciiString(), "2031-01-02T03:04:05+08:00")
        sizedDateReader.expectEnd()

        let numberReader = JsonFastReader(bytes("  -9876543210123456789.125  "))
        @Expect(numberReader.tryReadRawNumberToken())
        @Expect(numberReader.currentRawTokenByte(0), b'-')
        @Expect(numberReader.currentRawTokenDigit(1), 9)
        @Expect(numberReader.currentRawTokenByte(numberReader.currentRawTokenSize() - 4), b'.')
        @Expect(numberReader.currentRawTokenAsciiString(), "-9876543210123456789.125")
        numberReader.expectEnd()
    }

    @TestCase
    func rawTokenReaderApiLeavesEscapedStringsForFallback(): Unit {
        let escapedReader = JsonFastReader(bytes("\"\\u0032031-01-02T03:04:05Z\""))
        @Expect(!escapedReader.tryReadRawAsciiStringToken())
        @Expect(jsonFastReadRfc3339DateTime(escapedReader), DateTime.parse("2031-01-02T03:04:05Z", DateTimeFormat.RFC3339))
        escapedReader.expectEnd()
    }

    @TestCase
    func readerHelpersFallbackForEscapedDateAndExponentNumber(): Unit {
        let escapedDateReader = JsonFastReader(bytes("\"\\u0032024-06-20T14:42:33+08:00\""))
        @Expect(jsonFastReadRfc3339DateTime(escapedDateReader), DateTime.parse("2024-06-20T14:42:33+08:00", DateTimeFormat.RFC3339))
        escapedDateReader.expectEnd()

        let exponentReader = JsonFastReader(bytes("12.50e1"))
        @Expect(jsonFastReadDecimal(exponentReader), Decimal.parse("12.50e1"))
        exponentReader.expectEnd()
    }

    @TestCase
    func rawNumberHelpersParseGenericLargeIntegerAndScaledDecimal(): Unit {
        let bigReader = JsonFastReader(bytes("-1234567890123456789012345678901234567890"))
        @Expect(jsonFastReadBigInt(bigReader), BigInt.parse("-1234567890123456789012345678901234567890"))
        bigReader.expectEnd()

        let publicBigReader = JsonFastReader(bytes("9223372036854775808"))
        @Expect(publicBigReader.readRawBigInt(), BigInt.parse("9223372036854775808"))
        publicBigReader.expectEnd()

        let decimalReader = JsonFastReader(bytes("-987654321012345678901234567890.1250"))
        let decimal = jsonFastReadDecimal(decimalReader)
        @Expect(decimal, Decimal.parse("-987654321012345678901234567890.1250"))
        @Expect(decimal.toString(), "-987654321012345678901234567890.1250")
        decimalReader.expectEnd()

        let publicDecimalReader = JsonFastReader(bytes("1.250e2"))
        @Expect(publicDecimalReader.readRawDecimal(), Decimal.parse("1.250e2"))
        publicDecimalReader.expectEnd()
    }

    @TestCase
    func rawArrayListDateTimeHelperUsesRawReaderAndFallback(): Unit {
        let compactReader = JsonFastReader(bytes("[\"2031-01-02T03:04:05Z\",\"2031-01-02T08:34:05+05:30\"]"))
        let compactValues = jsonFastReadArrayListRfc3339DateTime(compactReader)
        @Expect(compactValues.size, 2)
        @Expect(compactValues[0], DateTime.parse("2031-01-02T03:04:05Z", DateTimeFormat.RFC3339))
        @Expect(compactValues[1], DateTime.parse("2031-01-02T08:34:05+05:30", DateTimeFormat.RFC3339))
        compactReader.expectEnd()

        let fallbackReader = JsonFastReader(bytes("[ \"\\u0032031-01-02T03:04:05Z\" , \"2031-01-02T02:04:05-01:00\" ]"))
        let fallbackValues = jsonFastReadArrayListRfc3339DateTime(fallbackReader)
        @Expect(fallbackValues.size, 2)
        @Expect(fallbackValues[0], DateTime.parse("2031-01-02T03:04:05Z", DateTimeFormat.RFC3339))
        @Expect(fallbackValues[1], DateTime.parse("2031-01-02T02:04:05-01:00", DateTimeFormat.RFC3339))
        fallbackReader.expectEnd()
    }

    @TestCase
    func rawStringMapDecimalHelperUsesRawReaderAndFallback(): Unit {
        let compactReader = JsonFastReader(bytes("{\"k1\":7.125,\"k2\":-3.50}"))
        let compactValues = jsonFastReadHashMapStringDecimal(compactReader)
        @Expect(compactValues.size, 2)
        @Expect(compactValues["k1"], Decimal.parse("7.125"))
        @Expect(compactValues["k2"], Decimal.parse("-3.50"))
        @Expect(compactValues["k2"].toString(), "-3.50")
        compactReader.expectEnd()

        let fallbackReader = JsonFastReader(bytes("{ \"k\\u0031\" : 1.25e2, \"k2\" : 0.004 }"))
        let fallbackValues = jsonFastReadHashMapStringDecimal(fallbackReader)
        @Expect(fallbackValues.size, 2)
        @Expect(fallbackValues["k1"], Decimal.parse("1.25e2"))
        @Expect(fallbackValues["k2"], Decimal.parse("0.004"))
        fallbackReader.expectEnd()
    }

    @TestCase
    func rawNumberContainerHelpersFallbackForWhitespaceAndEscapedKeys(): Unit {
        let decimalArrayReader = JsonFastReader(bytes("[ 1.250 , -0.50 , 6e2 ]"))
        let decimalArrayValues = jsonFastReadArrayListDecimal(decimalArrayReader)
        @Expect(decimalArrayValues.size, 3)
        @Expect(decimalArrayValues[0], Decimal.parse("1.250"))
        @Expect(decimalArrayValues[0].toString(), "1.250")
        @Expect(decimalArrayValues[1], Decimal.parse("-0.50"))
        @Expect(decimalArrayValues[2], Decimal.parse("6e2"))
        decimalArrayReader.expectEnd()

        let bigIntMapReader = JsonFastReader(bytes("{ \"n\\u0031\" : 12345678901234567890, \"n2\" : -42 }"))
        let bigIntMapValues = jsonFastReadHashMapStringBigInt(bigIntMapReader)
        @Expect(bigIntMapValues.size, 2)
        @Expect(bigIntMapValues["n1"], BigInt.parse("12345678901234567890"))
        @Expect(bigIntMapValues["n2"], BigInt.parse("-42"))
        bigIntMapReader.expectEnd()
    }

    @TestCase
    func temporalStatsCompactRatiosAndFallbackKeysKeepSemantics(): Unit {
        let compact = YJson.decodeStringWith(
            TemporalStatsJson,
            compactTemporalStatsText("{\"p50\":12.5,\"p99\":98.25}")
        )
        @Expect(compact.checkpoints.size, 2)
        @Expect(compact.ratios["p50"], Decimal.parse("12.5"))
        @Expect(compact.ratios["p99"], Decimal.parse("98.25"))

        let escapedKey = YJson.decodeStringWith(
            TemporalStatsJson,
            compactTemporalStatsText("{\"p\\u00350\":12.5,\"p99\":98.25}")
        )
        @Expect(escapedKey.ratios["p50"], Decimal.parse("12.5"))
        @Expect(escapedKey.ratios["p99"], Decimal.parse("98.25"))
    }

    @TestCase
    func temporalStatsOrderedFieldHelpersFallbackForUncachedValues(): Unit {
        let value = YJson.decodeStringWith(
            TemporalStatsJson,
            "{\"createdAt\":\"\\u0032024-06-20T14:42:33+08:00\"," +
                "\"totalEvents\":-42," +
                "\"averageLatency\":12.50," +
                "\"checkpoints\":[\"2024-06-20T14:42:33+08:00\",\"2024-06-20T15:12:33+08:00\"]," +
                "\"ratios\":{\"p50\":12.5,\"p99\":98.25}}"
        )
        @Expect(value.createdAt, DateTime.parse("2024-06-20T14:42:33+08:00", DateTimeFormat.RFC3339))
        @Expect(value.totalEvents, BigInt.parse("-42"))
        @Expect(value.averageLatency, Decimal.parse("12.50"))
        @Expect(value.averageLatency.toString(), "12.50")
    }

    @TestCase
    func temporalStatsCommonPayloadVariantsCreateFreshContainers(): Unit {
        let p50FirstText = compactTemporalStatsText("{\"p50\":12.5,\"p99\":98.25}")
        let p50First = YJson.decodeStringWith(TemporalStatsJson, p50FirstText)
        assertTemporalStatsBenchmarkValue(p50First)

        p50First.checkpoints.add(DateTime.parse("2024-06-20T16:12:33+08:00", DateTimeFormat.RFC3339))
        p50First.ratios.add("p01", Decimal.parse("0.001"))
        let p50FirstAgain = YJson.decodeStringWith(TemporalStatsJson, p50FirstText)
        assertTemporalStatsBenchmarkValue(p50FirstAgain)

        let p50Bytes = YJson.decodeBytesWith(TemporalStatsJson, bytes(p50FirstText))
        assertTemporalStatsBenchmarkValue(p50Bytes)

        let p99First = YJson.decodeStringWith(
            TemporalStatsJson,
            compactTemporalStatsText("{\"p99\":98.25,\"p50\":12.5}")
        )
        assertTemporalStatsBenchmarkValue(p99First)

        let whitespaceFallback = YJson.decodeStringWith(TemporalStatsJson, " " + p50FirstText)
        assertTemporalStatsBenchmarkValue(whitespaceFallback)
    }
}
