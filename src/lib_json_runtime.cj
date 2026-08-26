package yjson

import std.sync.*

/// Raised when process-wide JSON acceleration cannot be configured safely.
public class JsonAccelerationException <: JsonException {
    public init(message: String, code!: String = "acceleration_error") {
        super(message, code: code, path: "$")
    }

    protected override func getClassName(): String { "JsonAccelerationException" }
}

/// Versioned cross-package activation seam used by yjson_native_accel.
/// Applications configure it through YJsonNativeAccel.initialize().
public interface JsonAccelerationProviderV1 {
    func identity(): String
    func protocolVersion(): Int64
    func abiVersion(): Int64
    func activate(): Unit
}

private const YJSON_ACCEL_PROTOCOL_V1: Int64 = 1
private const YJSON_ACCEL_ABI_V1: Int64 = 1
private const YJSON_RUNTIME_UNCONFIGURED: Int64 = 0
private const YJSON_RUNTIME_PURE_FROZEN: Int64 = 1
private const YJSON_RUNTIME_NATIVE_FROZEN: Int64 = 2

private let yJsonRuntimeMutex = Mutex()
private var yJsonRuntimeState: Int64 = YJSON_RUNTIME_UNCONFIGURED
private var yJsonRuntimeProviderIdentity: String = ""

/// Freezes the portable engine on the first ordinary YJson call.
func freezeYJsonRuntime(): Unit {
    synchronized(yJsonRuntimeMutex) {
        if (yJsonRuntimeState == YJSON_RUNTIME_UNCONFIGURED) {
            yJsonRuntimeState = YJSON_RUNTIME_PURE_FROZEN
        }
    }
}

/// Internal product seam. Optional acceleration packages must call this only
/// from their single public initialize entry point.
public func initializeYJsonAccelerationV1(provider: JsonAccelerationProviderV1): Unit {
    synchronized(yJsonRuntimeMutex) {
        if (provider.protocolVersion() != YJSON_ACCEL_PROTOCOL_V1) {
            throw JsonAccelerationException(
                "Acceleration protocol mismatch: expected 1, got ${provider.protocolVersion()}",
                code: "acceleration_protocol_mismatch")
        }
        if (provider.abiVersion() != YJSON_ACCEL_ABI_V1) {
            throw JsonAccelerationException(
                "Acceleration ABI mismatch: expected 1, got ${provider.abiVersion()}",
                code: "acceleration_abi_mismatch")
        }
        if (yJsonRuntimeState == YJSON_RUNTIME_PURE_FROZEN) {
            throw JsonAccelerationException(
                "YJson is already frozen in portable mode; initialize acceleration before the first YJson call",
                code: "acceleration_initialized_too_late")
        }
        if (yJsonRuntimeState == YJSON_RUNTIME_NATIVE_FROZEN) {
            if (yJsonRuntimeProviderIdentity != provider.identity()) {
                throw JsonAccelerationException(
                    "A different JSON acceleration provider is already active",
                    code: "acceleration_provider_conflict")
            }
            return
        }
        try {
            provider.activate()
        } catch (error: JsonAccelerationException) {
            throw error
        } catch (error: Exception) {
            throw JsonAccelerationException(
                "JSON acceleration initialization failed: ${error.message}",
                code: "acceleration_initialization_failed")
        }
        yJsonRuntimeProviderIdentity = provider.identity()
        yJsonRuntimeState = YJSON_RUNTIME_NATIVE_FROZEN
    }
}

/// Version queried by generated codecs. Patch releases remain compatible as
/// long as this value stays unchanged.
public func yJsonGeneratedProtocolVersion(): Int64 { 1 }
