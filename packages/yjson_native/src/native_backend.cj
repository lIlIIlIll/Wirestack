package yjson_native

import yjson.*

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

private class CJsonNativeScannerBackend <: JsonNativeScannerBackend & JsonNativeNumericScannerBackend & JsonNativeNumericTapeBackend & JsonNativeFloatParserBackend {
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
    public func scanNumericTape(input: CPointer<UInt8>, len: Int64, start: Int64, pageBytes: Int64, flags: UInt32, tokens: CPointer<UInt64>, tokenCap: Int64, outNext: CPointer<Int64>, outCount: CPointer<Int64>, outError: CPointer<Int64>): Int32 {
        unsafe { YJ_JSON_ScanNumericTape(input, len, start, pageBytes, flags, tokens, tokenCap, outNext, outCount, outError) }
    }

    public func scanString(input: CPointer<UInt8>, len: Int64, start: Int64, flags: UInt32, outEnd: CPointer<Int64>, outError: CPointer<Int64>): Int32 {
        unsafe { YJ_JSON_ScanString(input, len, start, flags, outEnd, outError) }
    }

    public func decodeString(input: CPointer<UInt8>, len: Int64, start: Int64, flags: UInt32, output: CPointer<UInt8>, outputCap: Int64, outEnd: CPointer<Int64>, outWritten: CPointer<Int64>, outError: CPointer<Int64>): Int32 {
        unsafe { YJ_JSON_DecodeString(input, len, start, flags, output, outputCap, outEnd, outWritten, outError) }
    }
}

// Backend activation is process-global. Keep the modes explicit so a
// FloatOnly or NumericOnly experiment cannot silently mask a later full
// activation, and disabling one mode cannot leave the other seams installed.
private const YJSON_NATIVE_MODE_NONE: Int32 = 0
private const YJSON_NATIVE_MODE_FULL: Int32 = 1
private const YJSON_NATIVE_MODE_FLOAT_ONLY: Int32 = 2
private const YJSON_NATIVE_MODE_NUMERIC_ONLY: Int32 = 3
private var yJsonNativeMode: Int32 = YJSON_NATIVE_MODE_NONE

private func beginNativeMode(mode: Int32, name: String): Bool {
    if (yJsonNativeMode == YJSON_NATIVE_MODE_NONE) {
        return true
    }
    if (yJsonNativeMode == mode) {
        return false
    }
    throw IllegalStateException(
        "${name} cannot be combined with another yjson_native activation mode")
}

private func endNativeMode(mode: Int32, name: String): Bool {
    if (yJsonNativeMode == YJSON_NATIVE_MODE_NONE) {
        return false
    }
    if (yJsonNativeMode != mode) {
        throw IllegalStateException(
            "${name} does not match the active yjson_native activation mode")
    }
    return true
}

// Package-local test support. Keeping this out of the public surface lets the
// optional package verify that the linked scanner archive is callable without
// making the low-level C ABI part of yjson's API.
func nativeScannerCapabilitiesForTesting(): UInt32 {
    unsafe { YJ_JSON_SimdCaps() }
}

public func enableYJsonNative(): Unit {
    if (beginNativeMode(YJSON_NATIVE_MODE_FULL, "enableYJsonNative")) {
        let backend = CJsonNativeScannerBackend()
        installJsonNativeScannerBackend(backend)
        installJsonNativeNumericScannerBackend(backend)
        installJsonNativeNumericTapeBackend(backend)
        installJsonNativeFloatParserBackend(backend)
        yJsonNativeMode = YJSON_NATIVE_MODE_FULL
    }
}


/// Installs only the bounded native Float64 token parser. The foreign call is
/// deliberately kept separate from the structural and bulk-number backends so
/// its cost and semantic surface can be measured independently. Activation
/// modes are mutually exclusive; call the matching disable function before
/// selecting another isolated mode.
public func enableYJsonNativeFloatOnly(): Unit {
    if (beginNativeMode(YJSON_NATIVE_MODE_FLOAT_ONLY, "enableYJsonNativeFloatOnly")) {
        let backend = CJsonNativeScannerBackend()
        installJsonNativeFloatParserBackend(backend)
        yJsonNativeMode = YJSON_NATIVE_MODE_FLOAT_ONLY
    }
}


/// Removes the FloatOnly activation. Calling it while another mode is active
/// throws instead of leaving the process-global backend state partially reset.
public func disableYJsonNativeFloatOnly(): Unit {
    if (endNativeMode(YJSON_NATIVE_MODE_FLOAT_ONLY, "disableYJsonNativeFloatOnly")) {
        uninstallJsonNativeFloatParserBackend()
        yJsonNativeMode = YJSON_NATIVE_MODE_NONE
    }
}


/// Installs only the additive bulk-number seam. Benchmarks and deployments can
/// evaluate it independently of the established string/structural scanner.
/// Activation modes are mutually exclusive.
public func enableYJsonNativeNumericOnly(): Unit {
    if (beginNativeMode(YJSON_NATIVE_MODE_NUMERIC_ONLY, "enableYJsonNativeNumericOnly")) {
        let backend = CJsonNativeScannerBackend()
        installJsonNativeNumericScannerBackend(backend)
        installJsonNativeNumericTapeBackend(backend)
        yJsonNativeMode = YJSON_NATIVE_MODE_NUMERIC_ONLY
    }
}


/// Removes the NumericOnly activation. Calling it while another mode is active
/// throws instead of leaving the process-global backend state partially reset.
public func disableYJsonNativeNumericOnly(): Unit {
    if (endNativeMode(YJSON_NATIVE_MODE_NUMERIC_ONLY, "disableYJsonNativeNumericOnly")) {
        uninstallJsonNativeNumericScannerBackend()
        yJsonNativeMode = YJSON_NATIVE_MODE_NONE
    }
}
