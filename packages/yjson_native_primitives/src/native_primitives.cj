package yjson_native_primitives

import yjson.*

@FastNative
foreign func YJ_JSON_ProbeV1(): UInt32

@FastNative
foreign func YJ_JSON_SimdCaps(): UInt32

@FastNative
foreign func YJ_JSON_ParseDouble(input: CPointer<UInt8>, len: Int64, start: Int64,
    tokenLength: Int64): Float64

@FastNative
foreign func YJ_JSON_SkipValue(input: CPointer<UInt8>, len: Int64, start: Int64, flags: UInt32, outEnd: CPointer<Int64>, outError: CPointer<Int64>): Int32

@FastNative
foreign func YJ_JSON_ScanObjectFields(input: CPointer<UInt8>, len: Int64, start: Int64, flags: UInt32, fields: CPointer<UInt64>, fieldCap: Int64, outEnd: CPointer<Int64>, outError: CPointer<Int64>): Int32

@FastNative
foreign func YJ_JSON_ScanArrayElements(input: CPointer<UInt8>, len: Int64, start: Int64, flags: UInt32, elements: CPointer<UInt64>, elementCap: Int64, outEnd: CPointer<Int64>, outError: CPointer<Int64>): Int32

@FastNative
foreign func YJ_JSON_ScanNumericArrayChunk(input: CPointer<UInt8>, len: Int64, start: Int64, flags: UInt32, tokens: CPointer<UInt64>, tokenCap: Int64, outNext: CPointer<Int64>, outCount: CPointer<Int64>, outDone: CPointer<Int64>, outError: CPointer<Int64>): Int32
@FastNative
foreign func YJ_JSON_ScanNumericTape(input: CPointer<UInt8>, len: Int64, start: Int64, pageBytes: Int64, flags: UInt32, tokens: CPointer<UInt64>, tokenCap: Int64, outNext: CPointer<Int64>, outCount: CPointer<Int64>, outError: CPointer<Int64>): Int32

@FastNative
foreign func YJ_JSON_ScanString(input: CPointer<UInt8>, len: Int64, start: Int64, flags: UInt32, outEnd: CPointer<Int64>, outError: CPointer<Int64>): Int32

@FastNative
foreign func YJ_JSON_DecodeString(input: CPointer<UInt8>, len: Int64, start: Int64, flags: UInt32, output: CPointer<UInt8>, outputCap: Int64, outEnd: CPointer<Int64>, outWritten: CPointer<Int64>, outError: CPointer<Int64>): Int32

@FastNative
foreign func YJ_JSON_EscapeString(input: CPointer<UInt8>, len: Int64, htmlSafe: Bool,
    output: CPointer<UInt8>, outputCap: Int64, outWritten: CPointer<Int64>): Int32

@FastNative
foreign func YJ_JSON_FormatInt64Array(values: CPointer<Int64>, count: Int64,
    output: CPointer<UInt8>, outputCap: Int64, outputOffset: Int64,
    outWritten: CPointer<Int64>): Int32

@FastNative
foreign func YJ_JSON_ParseInt64Array(input: CPointer<UInt8>, len: Int64, start: Int64,
    values: CPointer<Int64>, valueCap: Int64, outEnd: CPointer<Int64>,
    outCount: CPointer<Int64>, outError: CPointer<Int64>): Int32

private class CJsonNativeScannerBackend <: JsonNativeAccelerationPrimitivesV1 {
    public func simdCaps(): UInt32 { unsafe { YJ_JSON_SimdCaps() } }

    public func parseFloat64(input: CPointer<UInt8>, len: Int64, start: Int64, tokenLength: Int64): Float64 {
        unsafe { YJ_JSON_ParseDouble(input, len, start, tokenLength) }
    }

    public func skipValue(input: CPointer<UInt8>, len: Int64, start: Int64, flags: UInt32, outEnd: CPointer<Int64>, outError: CPointer<Int64>): Int32 {
        unsafe { YJ_JSON_SkipValue(input, len, start, flags, outEnd, outError) }
    }

    public func scanObjectFields(input: CPointer<UInt8>, len: Int64, start: Int64, flags: UInt32, fields: CPointer<UInt64>, fieldCap: Int64, outEnd: CPointer<Int64>, outError: CPointer<Int64>): Int32 {
        unsafe { YJ_JSON_ScanObjectFields(input, len, start, flags, fields, fieldCap, outEnd, outError) }
    }

    public func scanArrayElements(input: CPointer<UInt8>, len: Int64, start: Int64, flags: UInt32, elements: CPointer<UInt64>, elementCap: Int64, outEnd: CPointer<Int64>, outError: CPointer<Int64>): Int32 {
        unsafe { YJ_JSON_ScanArrayElements(input, len, start, flags, elements, elementCap, outEnd, outError) }
    }

    public func scanNumericArrayChunk(input: CPointer<UInt8>, len: Int64, start: Int64, flags: UInt32, tokens: CPointer<UInt64>, tokenCap: Int64, outNext: CPointer<Int64>, outCount: CPointer<Int64>, outDone: CPointer<Int64>, outError: CPointer<Int64>): Int32 {
        unsafe { YJ_JSON_ScanNumericArrayChunk(input, len, start, flags, tokens, tokenCap, outNext, outCount, outDone, outError) }
    }
    public func parseInt64Array(input: CPointer<UInt8>, len: Int64, start: Int64,
        values: CPointer<Int64>, valueCap: Int64, outEnd: CPointer<Int64>,
        outCount: CPointer<Int64>, outError: CPointer<Int64>): Int32 {
        unsafe { YJ_JSON_ParseInt64Array(input, len, start, values, valueCap,
            outEnd, outCount, outError) }
    }
    public func scanNumericTape(input: CPointer<UInt8>, len: Int64, start: Int64, pageBytes: Int64, flags: UInt32, tokens: CPointer<UInt64>, tokenCap: Int64, outNext: CPointer<Int64>, outCount: CPointer<Int64>, outError: CPointer<Int64>): Int32 {
        unsafe { YJ_JSON_ScanNumericTape(input, len, start, pageBytes, flags, tokens, tokenCap, outNext, outCount, outError) }
    }

    public func scanString(input: CPointer<UInt8>, len: Int64, start: Int64, flags: UInt32, outEnd: CPointer<Int64>, outError: CPointer<Int64>): Int32 {
        unsafe { YJ_JSON_ScanString(input, len, start, flags, outEnd, outError) }
    }

    public func decodeString(input: CPointer<UInt8>, len: Int64, start: Int64, flags: UInt32, output: CPointer<UInt8>, outputCap: Int64, outEnd: CPointer<Int64>, outWritten: CPointer<Int64>, outError: CPointer<Int64>): Int32 {
        unsafe { YJ_JSON_DecodeString(input, len, start, flags, output, outputCap, outEnd, outWritten, outError) }
    }

    public func escapeString(input: CPointer<UInt8>, len: Int64, htmlSafe: Bool,
        output: CPointer<UInt8>, outputCap: Int64, outWritten: CPointer<Int64>): Int32 {
        unsafe { YJ_JSON_EscapeString(input, len, htmlSafe, output, outputCap, outWritten) }
    }

    public func formatInt64Array(values: CPointer<Int64>, count: Int64,
        output: CPointer<UInt8>, outputCap: Int64, outputOffset: Int64,
        outWritten: CPointer<Int64>): Int32 {
        unsafe { YJ_JSON_FormatInt64Array(values, count, output, outputCap, outputOffset,
            outWritten) }
    }
}

private var yJsonNativeEnabled: Bool = false

// Package-local test support. Keeping this out of the public surface lets the
// optional package verify that the linked scanner archive is callable without
// making the low-level C ABI part of yjson's API.
func nativeScannerCapabilitiesForTesting(): UInt32 {
    unsafe { YJ_JSON_SimdCaps() }
}

func enableYJsonNative(): Unit {
    if (yJsonNativeEnabled) { return }
    activateJsonNativePrimitivesV1(CJsonNativeScannerBackend())
    yJsonNativeEnabled = true
}

private class CustomNativeAccelerationProviderV1 <: JsonAccelerationProviderV1 {
    public func identity(): String { "yjson-custom-native-v1" }
    public func protocolVersion(): Int64 { 1 }
    public func abiVersion(): Int64 { 1 }
    public func activate(): Unit {
        // Resolve and validate the full linked primitive bundle before the
        // process-wide runtime state is frozen.
        let probe = unsafe { YJ_JSON_ProbeV1() }
        if (probe != 0x594A0101u32) {
            throw JsonAccelerationException(
                "Custom Native primitive ABI probe mismatch: expected 0x594A0101, got ${probe}",
                code: "acceleration_abi_mismatch")
        }
        let caps = nativeScannerCapabilitiesForTesting()
        if ((caps & 1u32) == 0u32) {
            throw JsonAccelerationException(
                "Custom Native primitives do not support this CPU",
                code: "acceleration_cpu_unsupported")
        }
        enableYJsonNative()
    }
}

/// Versioned closed SPI consumed by yjson_native_accel during startup.
public func initializeYJsonNativePrimitivesV1(): Unit {
    initializeYJsonAccelerationV1(CustomNativeAccelerationProviderV1())
}
