package yjson

import std.collection.*
import std.math.numeric.*
import std.time.*

private let JSON_FAST_BIGINT_CHUNK_DIGITS: Int64 = 18
private let JSON_FAST_BIGINT_CHUNK_BASE: Int64 = 1000000000000000000
private let JSON_FAST_BIGINT_ZERO: BigInt = BigInt(0)
private let JSON_FAST_BIGINT_CHUNK_BASE_VALUE: BigInt = BigInt(JSON_FAST_BIGINT_CHUNK_BASE)
private let JSON_FAST_RFC3339_OFFSET_CACHE_STEP_SECONDS: Int64 = 1800
private let JSON_FAST_RFC3339_OFFSET_CACHE_MIN_SECONDS: Int64 = -84600
private let JSON_FAST_RFC3339_OFFSET_CACHE_MAX_SECONDS: Int64 = 84600
private let JSON_FAST_DAYS_BEFORE_UNIX_EPOCH: Int64 = 719162
private let JSON_FAST_SECONDS_PER_DAY: Int64 = 86400
private let JSON_FAST_SECONDS_PER_HOUR: Int64 = 3600
private let JSON_FAST_SECONDS_PER_MINUTE: Int64 = 60

private func jsonFastDigitByte(value: Byte): Int64 {
    if (value < b'0' || value > b'9') {
        return -1
    }
    Int64(value - b'0')
}

private func jsonFastDigit(data: Array<Byte>, index: Int64): Int64 {
    jsonFastDigitByte(data[index])
}

private func jsonFastRawDigit(data: Array<Byte>, start: Int64, offset: Int64): Int64 {
    jsonFastDigitByte(data[start + offset])
}

private func jsonFastTwoDigits(data: Array<Byte>, index: Int64): Int64 {
    let first = jsonFastDigit(data, index)
    let second = jsonFastDigit(data, index + 1)
    if (first < 0 || second < 0) {
        return -1
    }
    first * 10 + second
}

private func jsonFastFourDigits(data: Array<Byte>, index: Int64): Int64 {
    let first = jsonFastTwoDigits(data, index)
    let second = jsonFastTwoDigits(data, index + 2)
    if (first < 0 || second < 0) {
        return -1
    }
    first * 100 + second
}

private func jsonFastRawTwoDigits(data: Array<Byte>, start: Int64, offset: Int64): Int64 {
    let first = jsonFastRawDigit(data, start, offset)
    let second = jsonFastRawDigit(data, start, offset + 1)
    if (first < 0 || second < 0) {
        return -1
    }
    first * 10 + second
}

private func jsonFastRawFourDigits(data: Array<Byte>, start: Int64, offset: Int64): Int64 {
    let first = jsonFastRawTwoDigits(data, start, offset)
    let second = jsonFastRawTwoDigits(data, start, offset + 2)
    if (first < 0 || second < 0) {
        return -1
    }
    first * 100 + second
}

private func jsonFastOffsetId(offsetSeconds: Int64): String {
    if (offsetSeconds == 0) {
        return "UTC"
    }
    let sign = if (offsetSeconds < 0) { "-" } else { "+" }
    let absOffset = if (offsetSeconds < 0) { -offsetSeconds } else { offsetSeconds }
    let hours = absOffset / 3600
    let minutes = (absOffset % 3600) / 60
    "${sign}${if (hours < 10) { "0" } else { "" }}${hours}:${if (minutes < 10) { "0" } else { "" }}${minutes}"
}

private func jsonFastBuildFixedOffsetTimeZoneCache(): Array<TimeZone> {
    let count = (JSON_FAST_RFC3339_OFFSET_CACHE_MAX_SECONDS - JSON_FAST_RFC3339_OFFSET_CACHE_MIN_SECONDS) /
        JSON_FAST_RFC3339_OFFSET_CACHE_STEP_SECONDS + 1
    let zones = Array<TimeZone>(count, repeat: TimeZone.UTC)
    var index: Int64 = 0
    var offsetSeconds = JSON_FAST_RFC3339_OFFSET_CACHE_MIN_SECONDS
    while (index < count) {
        zones[index] = if (offsetSeconds == 0) {
            TimeZone.UTC
        } else {
            TimeZone(jsonFastOffsetId(offsetSeconds), Duration.second * offsetSeconds)
        }
        index++
        offsetSeconds += JSON_FAST_RFC3339_OFFSET_CACHE_STEP_SECONDS
    }
    zones
}

private let JSON_FAST_RFC3339_FIXED_OFFSET_ZONES: Array<TimeZone> = jsonFastBuildFixedOffsetTimeZoneCache()

private func jsonFastFixedOffsetTimeZone(offsetSeconds: Int64): TimeZone {
    if (offsetSeconds == 0) {
        return TimeZone.UTC
    }
    if (offsetSeconds >= JSON_FAST_RFC3339_OFFSET_CACHE_MIN_SECONDS &&
        offsetSeconds <= JSON_FAST_RFC3339_OFFSET_CACHE_MAX_SECONDS &&
        offsetSeconds % JSON_FAST_RFC3339_OFFSET_CACHE_STEP_SECONDS == 0) {
        return JSON_FAST_RFC3339_FIXED_OFFSET_ZONES[
            (offsetSeconds - JSON_FAST_RFC3339_OFFSET_CACHE_MIN_SECONDS) /
                JSON_FAST_RFC3339_OFFSET_CACHE_STEP_SECONDS
        ]
    }
    TimeZone(jsonFastOffsetId(offsetSeconds), Duration.second * offsetSeconds)
}

private func jsonFastParseRfc3339Fallback(text: String): DateTime {
    DateTime.parse(text, DateTimeFormat.RFC3339)
}

private func jsonFastRfc3339LeapYear(year: Int64): Bool {
    year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
}

private func jsonFastRfc3339DaysInMonth(year: Int64, month: Int64): Int64 {
    match (month) {
        case 1 | 3 | 5 | 7 | 8 | 10 | 12 => 31
        case 4 | 6 | 9 | 11 => 30
        case 2 => if (jsonFastRfc3339LeapYear(year)) { 29 } else { 28 }
        case _ => 0
    }
}

private func jsonFastRfc3339DateFieldsValid(year: Int64, month: Int64, day: Int64): Bool {
    month >= 1 && month <= 12 && day >= 1 && day <= jsonFastRfc3339DaysInMonth(year, month)
}

private func jsonFastRfc3339DayOfYear(year: Int64, month: Int64, day: Int64): Int64 {
    let beforeMonth = match (month) {
        case 1 => 0
        case 2 => 31
        case 3 => 59
        case 4 => 90
        case 5 => 120
        case 6 => 151
        case 7 => 181
        case 8 => 212
        case 9 => 243
        case 10 => 273
        case 11 => 304
        case 12 => 334
        case _ => 0
    }
    if (month > 2 && jsonFastRfc3339LeapYear(year)) {
        return beforeMonth + day
    }
    beforeMonth + day - 1
}

private func jsonFastRfc3339DaysBeforeYear(year: Int64): Int64 {
    let previous = year - 1
    previous * 365 + previous / 4 - previous / 100 + previous / 400
}

private func jsonFastRfc3339EpochSecond(
    year: Int64,
    month: Int64,
    day: Int64,
    hour: Int64,
    minute: Int64,
    second: Int64,
    offsetSeconds: Int64
): Int64 {
    let days = jsonFastRfc3339DaysBeforeYear(year) +
        jsonFastRfc3339DayOfYear(year, month, day) -
        JSON_FAST_DAYS_BEFORE_UNIX_EPOCH
    days * JSON_FAST_SECONDS_PER_DAY +
        hour * JSON_FAST_SECONDS_PER_HOUR +
        minute * JSON_FAST_SECONDS_PER_MINUTE +
        second -
        offsetSeconds
}

private func jsonFastRfc3339BuildDateTime(
    year: Int64,
    month: Int64,
    day: Int64,
    hour: Int64,
    minute: Int64,
    second: Int64,
    offsetSeconds: Int64
): DateTime {
    let epochSecond = jsonFastRfc3339EpochSecond(year, month, day, hour, minute, second, offsetSeconds)
    let utc = DateTime.ofEpoch(second: epochSecond, nanosecond: 0)
    if (offsetSeconds == 0) {
        return utc
    }
    utc.inTimeZone(jsonFastFixedOffsetTimeZone(offsetSeconds))
}

private func jsonFastRfc3339BuildRawDateTime(
    reader: JsonFastReader,
    year: Int64,
    month: Int64,
    day: Int64,
    hour: Int64,
    minute: Int64,
    second: Int64,
    offsetSeconds: Int64
): DateTime {
    let epochSecond = jsonFastRfc3339EpochSecond(year, month, day, hour, minute, second, offsetSeconds)
    match (reader.currentRawDateTimeCache(epochSecond, offsetSeconds)) {
        case Some(value) => return value
        case None => ()
    }
    let utc = DateTime.ofEpoch(second: epochSecond, nanosecond: 0)
    let value = if (offsetSeconds == 0) {
        utc
    } else {
        utc.inTimeZone(jsonFastFixedOffsetTimeZone(offsetSeconds))
    }
    reader.setRawDateTimeCache(epochSecond, offsetSeconds, value)
    value
}

private func jsonFastParseRfc3339Core(text: String): DateTime {
    if (text.size != 20 && text.size != 25) {
        return jsonFastParseRfc3339Fallback(text)
    }

    let data = unsafe {
        text.rawData()
    }
    if (data[4] != b'-' || data[7] != b'-' || data[10] != b'T' ||
        data[13] != b':' || data[16] != b':') {
        return jsonFastParseRfc3339Fallback(text)
    }

    let year = jsonFastFourDigits(data, 0)
    let month = jsonFastTwoDigits(data, 5)
    let day = jsonFastTwoDigits(data, 8)
    let hour = jsonFastTwoDigits(data, 11)
    let minute = jsonFastTwoDigits(data, 14)
    let second = jsonFastTwoDigits(data, 17)
    if (year <= 0 || !jsonFastRfc3339DateFieldsValid(year, month, day) ||
        hour < 0 || hour > 23 || minute < 0 || minute > 59 || second < 0 || second > 59) {
        return jsonFastParseRfc3339Fallback(text)
    }

    var offsetSeconds: Int64 = 0
    if (text.size == 20) {
        if (data[19] != b'Z') {
            return jsonFastParseRfc3339Fallback(text)
        }
    } else {
        if ((data[19] != b'+' && data[19] != b'-') || data[22] != b':') {
            return jsonFastParseRfc3339Fallback(text)
        }
        let offsetHours = jsonFastTwoDigits(data, 20)
        let offsetMinutes = jsonFastTwoDigits(data, 23)
        if (offsetHours < 0 || offsetHours > 23 || offsetMinutes < 0 || offsetMinutes > 59) {
            return jsonFastParseRfc3339Fallback(text)
        }
        offsetSeconds = offsetHours * 3600 + offsetMinutes * 60
        if (data[19] == b'-') {
            offsetSeconds = -offsetSeconds
        }
    }

    jsonFastRfc3339BuildDateTime(year, month, day, hour, minute, second, offsetSeconds)
}

private func jsonFastParseRfc3339RawFallback(reader: JsonFastReader): DateTime {
    jsonFastParseRfc3339Fallback(reader.currentRawTokenAsciiString())
}

private func jsonFastParseRfc3339RawCore(reader: JsonFastReader): DateTime {
    let tokenSize = reader.currentRawTokenSize()
    if (tokenSize != 20 && tokenSize != 25) {
        return jsonFastParseRfc3339RawFallback(reader)
    }
    let data = reader.currentRawTokenData()
    let start = reader.currentRawTokenStartOffset()

    if (data[start + 4] != b'-' || data[start + 7] != b'-' ||
        data[start + 10] != b'T' || data[start + 13] != b':' ||
        data[start + 16] != b':') {
        return jsonFastParseRfc3339RawFallback(reader)
    }

    let year = jsonFastRawFourDigits(data, start, 0)
    let month = jsonFastRawTwoDigits(data, start, 5)
    let day = jsonFastRawTwoDigits(data, start, 8)
    let hour = jsonFastRawTwoDigits(data, start, 11)
    let minute = jsonFastRawTwoDigits(data, start, 14)
    let second = jsonFastRawTwoDigits(data, start, 17)
    if (year <= 0 || !jsonFastRfc3339DateFieldsValid(year, month, day) ||
        hour < 0 || hour > 23 || minute < 0 || minute > 59 || second < 0 || second > 59) {
        return jsonFastParseRfc3339RawFallback(reader)
    }

    var offsetSeconds: Int64 = 0
    if (tokenSize == 20) {
        if (data[start + 19] != b'Z') {
            return jsonFastParseRfc3339RawFallback(reader)
        }
    } else {
        let sign = data[start + 19]
        if ((sign != b'+' && sign != b'-') || data[start + 22] != b':') {
            return jsonFastParseRfc3339RawFallback(reader)
        }
        let offsetHours = jsonFastRawTwoDigits(data, start, 20)
        let offsetMinutes = jsonFastRawTwoDigits(data, start, 23)
        if (offsetHours < 0 || offsetHours > 23 || offsetMinutes < 0 || offsetMinutes > 59) {
            return jsonFastParseRfc3339RawFallback(reader)
        }
        offsetSeconds = offsetHours * 3600 + offsetMinutes * 60
        if (sign == b'-') {
            offsetSeconds = -offsetSeconds
        }
    }

    jsonFastRfc3339BuildRawDateTime(reader, year, month, day, hour, minute, second, offsetSeconds)
}

func jsonFastParseRfc3339DateTime(text: String): DateTime {
    jsonFastParseRfc3339Core(text)
}

func jsonFastReadRfc3339DateTime(reader: JsonFastReader): DateTime {
    if (reader.tryReadRawAsciiStringTokenSize2(20, 25)) {
        return jsonFastParseRfc3339RawCore(reader)
    }
    jsonFastParseRfc3339DateTime(reader.readRawString())
}

func jsonFastReadArrayListRfc3339DateTime(reader: JsonFastReader): ArrayList<DateTime> {
    let start = reader.position()
    if (reader.tryStartRawArrayCompact()) {
        let items = ArrayList<DateTime>(reader.suggestRawArrayCapacity())
        var first = true
        var compact = true
        while (reader.tryNextRawArrayItemCompact(first)) {
            if (reader.tryReadRawAsciiStringTokenSize2Compact(20, 25)) {
                items.add(jsonFastParseRfc3339RawCore(reader))
            } else {
                compact = false
                break
            }
            first = false
        }
        if (compact && reader.tryEndRawArrayCompact()) {
            return items
        }
    }
    reader.rewind(start)
    reader.startRawArray()
    let items = ArrayList<DateTime>(reader.suggestRawArrayCapacity())
    var first = true
    while (reader.nextRawArrayItem(first)) {
        items.add(jsonFastReadRfc3339DateTime(reader))
        first = false
    }
    reader.endRawArray()
    items
}

private func jsonFastAppendTwoDigits(builder: StringBuilder, value: Int64): Unit {
    if (value < 10) {
        builder.append("0")
    }
    builder.append(value)
}

private func jsonFastAppendFourDigits(builder: StringBuilder, value: Int64): Unit {
    if (value < 10) {
        builder.append("000")
    } else if (value < 100) {
        builder.append("00")
    } else if (value < 1000) {
        builder.append("0")
    }
    builder.append(value)
}

private func jsonFastFormatRfc3339Core(value: DateTime): Option<String> {
    if (value.nanosecond != 0) {
        return None<String>
    }
    if (value.year < 0 || value.year > 9999) {
        return None<String>
    }
    let offsetSeconds = value.zoneOffset.toSeconds()
    if (offsetSeconds % 60 != 0) {
        return None<String>
    }

    let builder = StringBuilder()
    jsonFastAppendFourDigits(builder, value.year)
    builder.append("-")
    jsonFastAppendTwoDigits(builder, value.month.toInteger())
    builder.append("-")
    jsonFastAppendTwoDigits(builder, value.dayOfMonth)
    builder.append("T")
    jsonFastAppendTwoDigits(builder, value.hour)
    builder.append(":")
    jsonFastAppendTwoDigits(builder, value.minute)
    builder.append(":")
    jsonFastAppendTwoDigits(builder, value.second)

    if (offsetSeconds == 0) {
        builder.append("Z")
    } else {
        let sign = if (offsetSeconds < 0) { "-" } else { "+" }
        let absOffset = if (offsetSeconds < 0) { -offsetSeconds } else { offsetSeconds }
        builder.append(sign)
        jsonFastAppendTwoDigits(builder, absOffset / 3600)
        builder.append(":")
        jsonFastAppendTwoDigits(builder, (absOffset % 3600) / 60)
    }
    Some(builder.toString())
}

func jsonFastFormatRfc3339DateTime(value: DateTime): String {
    match (jsonFastFormatRfc3339Core(value)) {
        case Some(text) => text
        case None => value.format(DateTimeFormat.RFC3339)
    }
}

func jsonFastParseBigInt(text: String): BigInt {
    BigInt.parse(text)
}

private func jsonFastPower10(digits: Int64): Int64 {
    var value: Int64 = 1
    for (_ in 0..digits) {
        value *= 10
    }
    value
}

private func jsonFastParseRawDigitsToBigInt(
    reader: JsonFastReader,
    start: Int64,
    end: Int64,
    skipOffset: Int64,
    negative: Bool,
    digitCount: Int64
): BigInt {
    let data = reader.currentRawTokenData()
    let tokenStart = reader.currentRawTokenStartOffset()
    if (digitCount <= JSON_FAST_BIGINT_CHUNK_DIGITS) {
        var cursor = start
        var value: Int64 = 0
        while (cursor < end) {
            if (cursor != skipOffset) {
                value = value * 10 + jsonFastRawDigit(data, tokenStart, cursor)
            }
            cursor++
        }
        if (negative) {
            return BigInt(-value)
        }
        return BigInt(value)
    }

    var firstChunkDigits = digitCount % JSON_FAST_BIGINT_CHUNK_DIGITS
    if (firstChunkDigits == 0) {
        firstChunkDigits = JSON_FAST_BIGINT_CHUNK_DIGITS
    }

    var cursor = start
    var remainingFirst = firstChunkDigits
    var firstChunk: Int64 = 0
    while (cursor < end && remainingFirst > 0) {
        if (cursor != skipOffset) {
            firstChunk = firstChunk * 10 + jsonFastRawDigit(data, tokenStart, cursor)
            remainingFirst--
        }
        cursor++
    }

    var result = BigInt(firstChunk)
    while (cursor < end) {
        var chunkDigits: Int64 = 0
        var chunk: Int64 = 0
        while (cursor < end && chunkDigits < JSON_FAST_BIGINT_CHUNK_DIGITS) {
            if (cursor != skipOffset) {
                chunk = chunk * 10 + jsonFastRawDigit(data, tokenStart, cursor)
                chunkDigits++
            }
            cursor++
        }
        let multiplier = if (chunkDigits == JSON_FAST_BIGINT_CHUNK_DIGITS) {
            JSON_FAST_BIGINT_CHUNK_BASE_VALUE
        } else {
            BigInt(jsonFastPower10(chunkDigits))
        }
        result = result * multiplier + BigInt(chunk)
    }

    if (negative) {
        return JSON_FAST_BIGINT_ZERO - result
    }
    result
}

private func jsonFastReadRawIntegerToken(reader: JsonFastReader): BigInt {
    let tokenSize = reader.currentRawTokenSize()
    if (tokenSize <= 0 || reader.currentRawTokenNumberScale() != 0 ||
        reader.currentRawTokenNumberHasExponent()) {
        return jsonFastParseBigInt(reader.currentRawTokenAsciiString())
    }
    let negative = reader.currentRawTokenNumberNegative()
    let digitCount = reader.currentRawTokenNumberDigitCount()
    if (reader.currentRawTokenNumberSmallUnscaledValid()) {
        let smallValue = reader.currentRawTokenNumberSmallUnscaled()
        return if (negative) { BigInt(-smallValue) } else { BigInt(smallValue) }
    }
    let digitsStart = if (negative) { 1 } else { 0 }
    jsonFastParseRawDigitsToBigInt(reader, digitsStart, tokenSize, -1, negative, digitCount)
}

func jsonFastReadBigInt(reader: JsonFastReader): BigInt {
    if (reader.tryReadRawNumberToken()) {
        return jsonFastReadRawIntegerToken(reader)
    }
    jsonFastParseBigInt(reader.readRawNumberLiteral())
}

func jsonFastReadArrayListBigInt(reader: JsonFastReader): ArrayList<BigInt> {
    let start = reader.position()
    if (reader.tryStartRawArrayCompact()) {
        let items = ArrayList<BigInt>(reader.suggestRawArrayCapacity())
        var first = true
        var compact = true
        while (reader.tryNextRawArrayItemCompact(first)) {
            if (reader.tryReadRawNumberTokenCompact()) {
                items.add(jsonFastReadRawIntegerToken(reader))
            } else {
                compact = false
                break
            }
            first = false
        }
        if (compact && reader.tryEndRawArrayCompact()) {
            return items
        }
    }
    reader.rewind(start)
    reader.startRawArray()
    let items = ArrayList<BigInt>(reader.suggestRawArrayCapacity())
    var first = true
    while (reader.nextRawArrayItem(first)) {
        items.add(jsonFastReadBigInt(reader))
        first = false
    }
    reader.endRawArray()
    items
}

func jsonFastReadHashMapStringBigInt(reader: JsonFastReader): HashMap<String, BigInt> {
    let start = reader.position()
    if (reader.tryStartRawObjectCompact()) {
        let result = HashMap<String, BigInt>(reader.suggestRawObjectCapacity())
        var first = true
        var compact = true
        while (reader.tryNextRawObjectFieldCompact(first)) {
            let key = reader.readRawNameAfterSeparator()
            if (reader.tryReadRawNumberTokenCompact()) {
                result.add(key, jsonFastReadRawIntegerToken(reader))
            } else {
                compact = false
                break
            }
            first = false
        }
        if (compact && reader.tryEndRawObject()) {
            return result
        }
    }
    reader.rewind(start)
    reader.startRawObject()
    let result = HashMap<String, BigInt>(reader.suggestRawObjectCapacity())
    var first = true
    while (reader.nextRawObjectField(first)) {
        let key = reader.readRawNameAfterSeparator()
        result.add(key, jsonFastReadBigInt(reader))
        first = false
    }
    reader.endRawObject()
    result
}

func jsonFastFormatBigInt(value: BigInt): String {
    value.toString()
}

func jsonFastParseDecimal(text: String): Decimal {
    Decimal.parse(text)
}

private func jsonFastReadRawDecimalToken(reader: JsonFastReader): Decimal {
    let tokenSize = reader.currentRawTokenSize()
    if (tokenSize <= 0 || reader.currentRawTokenNumberHasExponent()) {
        return jsonFastParseDecimal(reader.currentRawTokenAsciiString())
    }
    let negative = reader.currentRawTokenNumberNegative()
    if (negative && !reader.currentRawTokenNumberHasNonZero()) {
        return jsonFastParseDecimal(reader.currentRawTokenAsciiString())
    }
    let scale = reader.currentRawTokenNumberScale()
    if (scale > Int64(Int32.Max)) {
        return jsonFastParseDecimal(reader.currentRawTokenAsciiString())
    }
    let unscaled = if (reader.currentRawTokenNumberSmallUnscaledValid()) {
        let smallUnscaled = reader.currentRawTokenNumberSmallUnscaled()
        if (negative) {
            BigInt(-smallUnscaled)
        } else {
            BigInt(smallUnscaled)
        }
    } else {
        let digitsStart = if (negative) { 1 } else { 0 }
        let dotOffset = if (scale == 0) { -1 } else { tokenSize - scale - 1 }
        let digitCount = reader.currentRawTokenNumberDigitCount()
        jsonFastParseRawDigitsToBigInt(reader, digitsStart, tokenSize, dotOffset, negative, digitCount)
    }
    Decimal(unscaled, Int32(scale))
}

func jsonFastReadDecimal(reader: JsonFastReader): Decimal {
    if (reader.tryReadRawNumberToken()) {
        return jsonFastReadRawDecimalToken(reader)
    }
    jsonFastParseDecimal(reader.readRawNumberLiteral())
}

func jsonFastReadArrayListDecimal(reader: JsonFastReader): ArrayList<Decimal> {
    let start = reader.position()
    if (reader.tryStartRawArrayCompact()) {
        let items = ArrayList<Decimal>(reader.suggestRawArrayCapacity())
        var first = true
        var compact = true
        while (reader.tryNextRawArrayItemCompact(first)) {
            if (reader.tryReadRawNumberTokenCompact()) {
                items.add(jsonFastReadRawDecimalToken(reader))
            } else {
                compact = false
                break
            }
            first = false
        }
        if (compact && reader.tryEndRawArrayCompact()) {
            return items
        }
    }
    reader.rewind(start)
    reader.startRawArray()
    let items = ArrayList<Decimal>(reader.suggestRawArrayCapacity())
    var first = true
    while (reader.nextRawArrayItem(first)) {
        items.add(jsonFastReadDecimal(reader))
        first = false
    }
    reader.endRawArray()
    items
}

func jsonFastReadHashMapStringDecimal(reader: JsonFastReader): HashMap<String, Decimal> {
    let start = reader.position()
    if (reader.tryStartRawObjectCompact()) {
        let result = HashMap<String, Decimal>(reader.suggestRawObjectCapacity())
        var first = true
        var compact = true
        while (reader.tryNextRawObjectFieldCompact(first)) {
            let key = reader.readRawNameAfterSeparator()
            if (reader.tryReadRawNumberTokenCompact()) {
                result.add(key, jsonFastReadRawDecimalToken(reader))
            } else {
                compact = false
                break
            }
            first = false
        }
        if (compact && reader.tryEndRawObject()) {
            return result
        }
    }
    reader.rewind(start)
    reader.startRawObject()
    let result = HashMap<String, Decimal>(reader.suggestRawObjectCapacity())
    var first = true
    while (reader.nextRawObjectField(first)) {
        let key = reader.readRawNameAfterSeparator()
        result.add(key, jsonFastReadDecimal(reader))
        first = false
    }
    reader.endRawObject()
    result
}

// Macro-generated codecs live in the consumer package, so keep the
// arbitrary-precision container fast paths behind public context-aware
// bridges.  The raw helpers above intentionally do not know about decode-path
// depth; these wrappers preserve the same max-depth accounting as the existing
// generated String/Int64 container helpers.
func __yJsonReadFastArrayListBigInt(
    reader: JsonFastReader
): ArrayList<BigInt> {
    let context = GeneratedSupportV1.readState(reader)
    context.enterValue()
    try { jsonFastReadArrayListBigInt(reader) } finally { context.leaveValue() }
}

func __yJsonReadFastHashMapStringBigInt(
    reader: JsonFastReader
): HashMap<String, BigInt> {
    let context = GeneratedSupportV1.readState(reader)
    context.enterValue()
    try { jsonFastReadHashMapStringBigInt(reader) } finally { context.leaveValue() }
}

func __yJsonReadFastArrayListDecimal(
    reader: JsonFastReader
): ArrayList<Decimal> {
    let context = GeneratedSupportV1.readState(reader)
    context.enterValue()
    try { jsonFastReadArrayListDecimal(reader) } finally { context.leaveValue() }
}

func __yJsonReadFastHashMapStringDecimal(
    reader: JsonFastReader
): HashMap<String, Decimal> {
    let context = GeneratedSupportV1.readState(reader)
    context.enterValue()
    try { jsonFastReadHashMapStringDecimal(reader) } finally { context.leaveValue() }
}

public func jsonFastReadBigInt(reader: GeneratedSupportV1Reader): BigInt {
    jsonFastReadBigInt(yJsonGeneratedReaderV1(reader))
}

public func jsonFastReadDecimal(reader: GeneratedSupportV1Reader): Decimal {
    jsonFastReadDecimal(yJsonGeneratedReaderV1(reader))
}

public func __yJsonReadFastArrayListBigInt(
    reader: GeneratedSupportV1Reader
): ArrayList<BigInt> {
    __yJsonReadFastArrayListBigInt(yJsonGeneratedReaderV1(reader))
}

public func __yJsonReadFastHashMapStringBigInt(
    reader: GeneratedSupportV1Reader
): HashMap<String, BigInt> {
    __yJsonReadFastHashMapStringBigInt(yJsonGeneratedReaderV1(reader))
}

public func __yJsonReadFastArrayListDecimal(
    reader: GeneratedSupportV1Reader
): ArrayList<Decimal> {
    __yJsonReadFastArrayListDecimal(yJsonGeneratedReaderV1(reader))
}

public func __yJsonReadFastHashMapStringDecimal(
    reader: GeneratedSupportV1Reader
): HashMap<String, Decimal> {
    __yJsonReadFastHashMapStringDecimal(yJsonGeneratedReaderV1(reader))
}

func jsonFastFormatDecimal(value: Decimal): String {
    value.toString()
}
