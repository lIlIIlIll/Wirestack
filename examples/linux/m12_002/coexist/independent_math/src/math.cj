package independent_math

foreign func fixture_native_sum(value: Int64): Int64

public func checkedNativeWork(): Int64 {
    var total: Int64 = 0
    for (value in 1..11) { total += unsafe { fixture_native_sum(value) } }
    if (total != 985) { throw IllegalStateException("independent native arithmetic") }
    total
}
