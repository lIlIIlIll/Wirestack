package yjson_native

import yjson.*

@FastNative
foreign func YJ_JSON_SimdCaps(): UInt32

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

private class CJsonNativeScannerBackend <: JsonNativeScannerBackend & JsonNativeNumericScannerBackend & JsonNativeNumericTapeBackend {
    public func simdCaps(): UInt32 { unsafe { YJ_JSON_SimdCaps() } }

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

// Referenced by the aggregate package to make backend installation explicit
// and deterministic instead of depending on dead-code-sensitive side effects.
private var yJsonNativeEnabled = false

// Package-local test support. Keeping this out of the public surface lets the
// optional package verify that the linked scanner archive is callable without
// making the low-level C ABI part of yjson's API.
func nativeScannerCapabilitiesForTesting(): UInt32 {
    unsafe { YJ_JSON_SimdCaps() }
}

public func enableYJsonNative(): Unit {
    if (!yJsonNativeEnabled) {
        let backend = CJsonNativeScannerBackend()
        installJsonNativeScannerBackend(backend)
        installJsonNativeNumericScannerBackend(backend)
        installJsonNativeNumericTapeBackend(backend)
        yJsonNativeEnabled = true
    }
}


/// Installs only the additive bulk-number seam. Benchmarks and deployments can
/// evaluate it independently of the established string/structural scanner.
public func enableYJsonNativeNumericOnly(): Unit {
    if (!yJsonNativeEnabled) {
        let backend = CJsonNativeScannerBackend()
        installJsonNativeNumericScannerBackend(backend)
        installJsonNativeNumericTapeBackend(backend)
        yJsonNativeEnabled = true
    }
}


public func disableYJsonNativeNumericOnly(): Unit {
    uninstallJsonNativeNumericScannerBackend()
    yJsonNativeEnabled = false
}
