package wirestack.internal.http_model

/** Returns whether a domain-matched cookie scope reaches the origin's public suffix. */
public func cookieDomainCrossesPublicSuffix(domain: String, origin: String): Bool {
    let bytes = origin.toArray()
    if (bytes.isEmpty()) { return true }
    var suffixStart = bytes.size
    var start: Int64 = 0
    while (start < bytes.size) {
        var next = start
        while (next < bytes.size && bytes[next] != b'.') { next++ }
        if (COOKIE_PSL_EXCEPTION.contains(bytes, start)) {
            let suffixSize = if (next < bytes.size) { bytes.size - next - 1 } else { 0 }
            return domain.size <= suffixSize
        }
        if (start < suffixStart && (
            COOKIE_PSL_EXACT.contains(bytes, start) ||
            (next < bytes.size && COOKIE_PSL_WILDCARD.contains(bytes, next + 1))
        )) {
            suffixStart = start
        }
        // The implicit "*" rule applies only when no longer rule matched.
        if (next == bytes.size && suffixStart == bytes.size) { suffixStart = start }
        start = next + 1
    }
    domain.size <= bytes.size - suffixStart
}

/** One generated, immutable packed rule table shared by every cookie jar. */
internal class CookiePslTable {
    private let packed: Array<Byte>
    private let offsets: Array<Int64>

    internal init(packed: Array<Byte>, offsets: Array<Int64>) {
        this.packed = packed
        this.offsets = offsets
    }

    internal func contains(value: Array<Byte>, valueStart: Int64): Bool {
        var low: Int64 = 0
        var high: Int64 = offsets.size - 2
        while (low <= high) {
            let middle = low + (high - low) / 2
            let comparison = compare(
                offsets[middle],
                offsets[middle + 1],
                value,
                valueStart
            )
            if (comparison == 0) { return true }
            if (comparison < 0) { low = middle + 1 } else { high = middle - 1 }
        }
        false
    }

    private func compare(
        ruleStart: Int64,
        ruleEnd: Int64,
        value: Array<Byte>,
        valueStart: Int64
    ): Int64 {
        let ruleSize = ruleEnd - ruleStart
        let valueSize = value.size - valueStart
        let shared = if (ruleSize < valueSize) { ruleSize } else { valueSize }
        for (index in 0..shared) {
            let ruleByte = packed[ruleStart + index]
            let valueByte = value[valueStart + index]
            if (ruleByte < valueByte) { return -1 }
            if (ruleByte > valueByte) { return 1 }
        }
        if (ruleSize < valueSize) { -1 }
        else if (ruleSize > valueSize) { 1 }
        else { 0 }
    }
}
