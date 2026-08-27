package yjson_native_accel

import yjson.*
import yjson_native.*

/// Optional process-wide acceleration. Call once during application startup,
/// then continue using the ordinary YJson API.
public class YJsonNativeAccel {
    public static func initialize(): Unit {
        initializeYJsonAccelerationV1(customNativeAccelerationProviderV1())
    }
}
