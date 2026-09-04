package yjson

import std.convert.Parsable
import std.math.numeric.*
import std.time.*

const MAXVAL_I32: Int64 = 0x7FFF_FFFF
const MINVAL_I32: Int64 = -0x8000_0000
const MAXVAL_I16: Int64 = 0x7FFF
const MINVAL_I16: Int64 = -0x8000
const MAXVAL_I8: Int64 = 0x7F
const MINVAL_I8: Int64 = -0x80
const MAXVAL_UI32: UInt64 = 0xFFFF_FFFF
const MAXVAL_UI16: UInt64 = 0xFFFF
const MAXVAL_UI8: UInt64 = 0xFF

func ensureIntRange(typeName: String, decoded: Int64, min: Int64, max: Int64): Int64 {
    if (decoded < min || decoded > max) {
        throw JsonException("Cannot decode value as ${typeName}: out of range", code: "number_out_of_range")
    }
    decoded
}

func ensureUnsignedRange(typeName: String, decoded: UInt64, max: UInt64): UInt64 {
    if (decoded > max) {
        throw JsonException("Cannot decode value as ${typeName}: out of range", code: "number_out_of_range")
    }
    decoded
}

func decodeBigIntLike(value: JsonNode): BigInt {
    try {
        return jsonFastParseBigInt(value.asNumberText())
    } catch (_: JsonException) {
        match (value) {
            case jsonString: JsonStringValue => jsonFastParseBigInt(jsonString.value)
            case _ => throw JsonException("Cannot decode value as BigInt")
        }
    }
}

func decodeDecimalLike(value: JsonNode): Decimal {
    try {
        return jsonFastParseDecimal(value.asNumberText())
    } catch (_: JsonException) {
        match (value) {
            case jsonString: JsonStringValue => jsonFastParseDecimal(jsonString.value)
            case _ => throw JsonException("Cannot decode value as Decimal")
        }
    }
}

func decodeRuneText(text: String): Rune {
    let runes = text.toRuneArray()
    if (runes.size != 1) {
        throw JsonException("Rune requires exactly one Unicode scalar", code: "invalid_value")
    }
    runes[0]
}

let BoolJson: JsonCodec<Bool> = LambdaFastRawJsonCodec<Bool>(
    { value, writer => writer.writeBool(value) },
    { reader => reader.readBool() },
    { reader => reader.readRawBool() },
    { value, writer => writer.writeRawBool(value) }
)

let Int64Json: JsonCodec<Int64> = LambdaFastRawJsonCodec<Int64>(
    { value, writer => writer.writeInt64(value) },
    { reader => reader.readInt64() },
    { reader => reader.readRawInt64() },
    { value, writer => writer.writeRawInt64(value) }
)

let Int32Json: JsonCodec<Int32> = LambdaFastRawJsonCodec<Int32>(
    { value, writer => writer.writeInt64(Int64(value)) },
    { reader => Int32(ensureIntRange("Int32", reader.readInt64(), MINVAL_I32, MAXVAL_I32)) },
    { reader => reader.readRawInt32() },
    { value, writer => writer.writeRawInt64(Int64(value)) }
)

let Int16Json: JsonCodec<Int16> = LambdaFastRawJsonCodec<Int16>(
    { value, writer => writer.writeInt64(Int64(value)) },
    { reader => Int16(ensureIntRange("Int16", reader.readInt64(), MINVAL_I16, MAXVAL_I16)) },
    { reader => reader.readRawInt16() },
    { value, writer => writer.writeRawInt64(Int64(value)) }
)

let Int8Json: JsonCodec<Int8> = LambdaFastRawJsonCodec<Int8>(
    { value, writer => writer.writeInt64(Int64(value)) },
    { reader => Int8(ensureIntRange("Int8", reader.readInt64(), MINVAL_I8, MAXVAL_I8)) },
    { reader => reader.readRawInt8() },
    { value, writer => writer.writeRawInt64(Int64(value)) }
)

let UInt64Json: JsonCodec<UInt64> = LambdaFastRawJsonCodec<UInt64>(
    { value, writer => writer.writeUInt64(value) },
    { reader => reader.readUInt64() },
    { reader => reader.readRawUInt64() },
    { value, writer => writer.writeRawUInt64(value) }
)

let UInt32Json: JsonCodec<UInt32> = LambdaFastRawJsonCodec<UInt32>(
    { value, writer => writer.writeUInt64(UInt64(value)) },
    { reader => UInt32(ensureUnsignedRange("UInt32", reader.readUInt64(), MAXVAL_UI32)) },
    { reader => reader.readRawUInt32() },
    { value, writer => writer.writeRawUInt64(UInt64(value)) }
)

let UInt16Json: JsonCodec<UInt16> = LambdaFastRawJsonCodec<UInt16>(
    { value, writer => writer.writeUInt64(UInt64(value)) },
    { reader => UInt16(ensureUnsignedRange("UInt16", reader.readUInt64(), MAXVAL_UI16)) },
    { reader => reader.readRawUInt16() },
    { value, writer => writer.writeRawUInt64(UInt64(value)) }
)

let UInt8Json: JsonCodec<UInt8> = LambdaFastRawJsonCodec<UInt8>(
    { value, writer => writer.writeUInt64(UInt64(value)) },
    { reader => UInt8(ensureUnsignedRange("UInt8", reader.readUInt64(), MAXVAL_UI8)) },
    { reader => reader.readRawUInt8() },
    { value, writer => writer.writeRawUInt64(UInt64(value)) }
)

let Float64Json: JsonCodec<Float64> = LambdaFastRawJsonCodec<Float64>(
    { value, writer => writer.writeFloat64(value) },
    { reader => reader.readFloat64() },
    { reader => Float64.parse(reader.readRawNumberLiteral()) },
    { value, writer => writer.writeRawFloat64(value) }
)

let Float32Json: JsonCodec<Float32> = LambdaFastRawJsonCodec<Float32>(
    { value, writer => writer.writeFloat64(Float64(value)) },
    { reader => Float32(reader.readFloat64()) },
    { reader => Float32(Float64.parse(reader.readRawNumberLiteral())) },
    { value, writer => writer.writeRawFloat64(Float64(value)) }
)

let Float16Json: JsonCodec<Float16> = LambdaFastRawJsonCodec<Float16>(
    { value, writer => writer.writeFloat64(Float64(value)) },
    { reader => Float16(reader.readFloat64()) },
    { reader => Float16(Float64.parse(reader.readRawNumberLiteral())) },
    { value, writer => writer.writeRawFloat64(Float64(value)) }
)

// Public bridges keep macro-generated consumer code independent of the
// std.convert.Parsable extension imports used by this package's built-ins.
func jsonFastReadFloat64(reader: JsonFastReader): Float64 {
    if (jsonNativeFloatParserAvailable()) {
        if (reader.tryReadRawNumberToken()) {
            match (jsonNativeParseFloat64(reader)) {
                case Some(value) => return value
                case None => return Float64.parse(reader.currentRawTokenAsciiString())
            }
        }
    }
    Float64.parse(reader.readRawNumberLiteral())
}

func jsonFastReadFloat32(reader: JsonFastReader): Float32 {
    Float32(jsonFastReadFloat64(reader))
}

func jsonFastReadFloat16(reader: JsonFastReader): Float16 {
    Float16(jsonFastReadFloat64(reader))
}

public func jsonFastReadFloat64(reader: GeneratedSupportV1Reader): Float64 {
    jsonFastReadFloat64(yJsonGeneratedReaderV1(reader))
}

public func jsonFastReadFloat32(reader: GeneratedSupportV1Reader): Float32 {
    jsonFastReadFloat32(yJsonGeneratedReaderV1(reader))
}

public func jsonFastReadFloat16(reader: GeneratedSupportV1Reader): Float16 {
    jsonFastReadFloat16(yJsonGeneratedReaderV1(reader))
}

let StringJson: JsonCodec<String> = LambdaFastRawJsonCodec<String>(
    { value, writer => writer.writeString(value) },
    { reader => reader.readString() },
    { reader => reader.readRawString() },
    { value, writer => writer.writeRawString(value) }
)

let DateTimeJson: JsonCodec<DateTime> = LambdaFastRawJsonCodec<DateTime>(
    { value, writer => writer.writeString(jsonFastFormatRfc3339DateTime(value)) },
    { reader => jsonFastParseRfc3339DateTime(reader.readString()) },
    { reader => jsonFastParseRfc3339DateTime(reader.readRawString()) },
    { value, writer => writer.writeRawString(jsonFastFormatRfc3339DateTime(value)) }
)

let BigIntJson: JsonCodec<BigInt> = LambdaFastRawJsonCodec<BigInt>(
    { value, writer => writer.writeNumberLiteral(jsonFastFormatBigInt(value)) },
    { reader => jsonFastParseBigInt(reader.readNumberLiteral()) },
    { reader => jsonFastParseBigInt(reader.readRawNumberLiteral()) },
    { value, writer => writer.writeRawNumberValue(jsonFastFormatBigInt(value)) }
)

let DecimalJson: JsonCodec<Decimal> = LambdaFastRawJsonCodec<Decimal>(
    { value, writer => writer.writeNumberLiteral(jsonFastFormatDecimal(value)) },
    { reader => jsonFastParseDecimal(reader.readNumberLiteral()) },
    { reader => jsonFastParseDecimal(reader.readRawNumberLiteral()) },
    { value, writer => writer.writeRawNumberValue(jsonFastFormatDecimal(value)) }
)

let RuneJson: JsonCodec<Rune> = LambdaFastRawJsonCodec<Rune>(
    { value, writer => writer.writeString(value.toString()) },
    { reader => decodeRuneText(reader.readString()) },
    { reader => decodeRuneText(reader.readRawString()) },
    { value, writer => writer.writeRawString(value.toString()) }
)
