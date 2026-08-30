package yjson_native_accel

import yjson_native_primitives.*

/// Optional process-wide acceleration. Call once during application startup,
/// then continue using the ordinary YJson API.
public class YJsonNativeAccel {
    public static func initialize(): Unit {
        initializeYJsonNativePrimitivesV1()
    }
}
