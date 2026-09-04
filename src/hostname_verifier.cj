package wirestack

import std.collection.*

private let MAXIMUM_SAN_IDENTITIES: Int64 = 256
private let NATIVE_SAN_OK: Int32 = 0

foreign func wirestack_tls_certificate_subject_alt_names(
    input: CPointer<UInt8>,
    size: UInt64,
    output: CPointer<UInt8>,
    outputCapacity: UInt64,
    outputRequiredSize: CPointer<UInt64>,
    outputDnsCount: CPointer<UInt64>,
    outputIpCount: CPointer<UInt64>
): Int32

/**
 * Wirestack 公开 API：ReferenceIdentity。
 */
public enum ReferenceIdentity {
/**
 * Wirestack 公开 API：Dns。
 */
    | Dns(HostName)
/**
 * Wirestack 公开 API：Ip。
 */
    | Ip(IpAddress)
}

/**
 * Wirestack 公开 API：IdentityVerificationErrorCode。
 */
public enum IdentityVerificationErrorCode {
/**
 * Wirestack 公开 API：NoMatchingDnsSan。
 */
    | NoMatchingDnsSan
/**
 * Wirestack 公开 API：NoMatchingIpSan。
 */
    | NoMatchingIpSan
/**
 * Wirestack 公开 API：InvalidDnsSan。
 */
    | InvalidDnsSan
/**
 * Wirestack 公开 API：TooManySubjectAlternativeNames。
 */
    | TooManySubjectAlternativeNames
/**
 * Wirestack 公开 API：ZonedIpReference。
 */
    | ZonedIpReference
}

/**
 * Wirestack 公开 API：IdentityVerificationException。
 */
public class IdentityVerificationException <: Exception {
/**
 * Wirestack 公开 API：code。
 */
    public let code: IdentityVerificationErrorCode

/**
 * Wirestack 公开 API：init。
 * @param code 参数 code。
 * @param message 参数 message。
 */
    public init(code: IdentityVerificationErrorCode, message: String) {
        super(message)
        this.code = code
    }

/**
 * Wirestack 公开 API：getClassName。
 */
    protected override func getClassName(): String { "IdentityVerificationException" }
}

/** SAN-only names. A Common Name is intentionally not representable. */
public class CertificateSubjectAlternativeNames {
    private let dnsNames: Array<String>
    private let ipAddresses: Array<IpAddress>

/**
 * Wirestack 公开 API：init。
 * @param dnsNames 参数 dnsNames。
 * @param ipAddresses 参数 ipAddresses。
 */
    public init(dnsNames: Array<String>, ipAddresses: Array<IpAddress>) {
        if (dnsNames.size + ipAddresses.size > MAXIMUM_SAN_IDENTITIES) {
            throw IdentityVerificationException(
                IdentityVerificationErrorCode.TooManySubjectAlternativeNames,
                "certificate exceeds the subjectAltName identity limit"
            )
        }
        let canonical = Array<String>(dnsNames.size, {index =>
            canonicalizeDnsSan(dnsNames[index])
        })
        for (address in ipAddresses) {
            if (address.zone.isSome()) {
                throw IdentityVerificationException(
                    IdentityVerificationErrorCode.ZonedIpReference,
                    "certificate IP subjectAltName cannot contain an IPv6 zone"
                )
            }
        }
        this.dnsNames = canonical
        this.ipAddresses = ipAddresses.clone()
    }

/**
 * Wirestack 公开 API：dnsSubjectAlternativeNames。
 */
    public func dnsSubjectAlternativeNames(): Array<String> { dnsNames.clone() }
/**
 * Wirestack 公开 API：ipSubjectAlternativeNames。
 */
    public func ipSubjectAlternativeNames(): Array<IpAddress> { ipAddresses.clone() }
}

/**
 * Wirestack 公开 API：IdentityVerificationEvidence。
 */
public struct IdentityVerificationEvidence {
/**
 * Wirestack 公开 API：referenceIdentity。
 */
    public let referenceIdentity: String
/**
 * Wirestack 公开 API：matchedSubjectAlternativeName。
 */
    public let matchedSubjectAlternativeName: String
/**
 * Wirestack 公开 API：wildcard。
 */
    public let wildcard: Bool

/**
 * Wirestack 公开 API：init。
 * @param matchedSubjectAlternativeName 参数 matchedSubjectAlternativeName。
 * @param referenceIdentity 参数 referenceIdentity。
 * @param wildcard 参数 wildcard。
 */
    public init(referenceIdentity: String, matchedSubjectAlternativeName: String, wildcard: Bool) {
        this.referenceIdentity = referenceIdentity
        this.matchedSubjectAlternativeName = matchedSubjectAlternativeName
        this.wildcard = wildcard
    }
}

/**
 * Wirestack 公开 API：HostnameVerifier。
 */
public class HostnameVerifier {
/**
 * Wirestack 公开 API：verify。
 * @param names 参数 names。
 * @param reference 参数 reference。
 */
    public static func verify(
        names: CertificateSubjectAlternativeNames,
        reference: ReferenceIdentity
    ): IdentityVerificationEvidence {
        match (reference) {
            case ReferenceIdentity.Dns(host) => verifyDns(names, host)
            case ReferenceIdentity.Ip(address) => verifyIp(names, address)
        }
    }
}

internal func parseCertificateSubjectAlternativeNames(
    der: Array<Byte>
): CertificateSubjectAlternativeNames {
    let metadata = Array<UInt64>(3, repeat: 0u64)
    let firstStatus = unsafe {
        let input = acquireArrayRawData(der)
        let values = acquireArrayRawData(metadata)
        try {
            wirestack_tls_certificate_subject_alt_names(
                input.pointer,
                UInt64(der.size),
                CPointer<UInt8>(),
                0u64,
                values.pointer,
                values.pointer + 1,
                values.pointer + 2
            )
        } finally {
            releaseArrayRawData(values)
            releaseArrayRawData(input)
        }
    }
    if (firstStatus != NATIVE_SAN_OK || metadata[0] > 65536u64 ||
        metadata[1] + metadata[2] > UInt64(MAXIMUM_SAN_IDENTITIES)) {
        throw IdentityVerificationException(
            IdentityVerificationErrorCode.TooManySubjectAlternativeNames,
            "certificate subjectAltName extension is invalid or exceeds limits"
        )
    }
    if (metadata[0] == 0u64) {
        return CertificateSubjectAlternativeNames([], [])
    }
    let packed = Array<Byte>(Int64(metadata[0]), repeat: 0)
    let secondStatus = unsafe {
        let input = acquireArrayRawData(der)
        let output = acquireArrayRawData(packed)
        let values = acquireArrayRawData(metadata)
        try {
            wirestack_tls_certificate_subject_alt_names(
                input.pointer,
                UInt64(der.size),
                output.pointer,
                UInt64(packed.size),
                values.pointer,
                values.pointer + 1,
                values.pointer + 2
            )
        } finally {
            releaseArrayRawData(values)
            releaseArrayRawData(output)
            releaseArrayRawData(input)
        }
    }
    if (secondStatus != NATIVE_SAN_OK || metadata[0] != UInt64(packed.size)) {
        throw IdentityVerificationException(
            IdentityVerificationErrorCode.TooManySubjectAlternativeNames,
            "certificate subjectAltName extraction failed closed"
        )
    }
    decodeSubjectAlternativeNames(packed)
}

private func decodeSubjectAlternativeNames(
    packed: Array<Byte>
): CertificateSubjectAlternativeNames {
    let dnsNames = ArrayList<String>()
    let ipAddresses = ArrayList<IpAddress>()
    var offset: Int64 = 0
    while (offset < packed.size) {
        if (packed.size - offset < 3) { throw invalidDnsSan() }
        let kind = packed[offset]
        let length = Int64(packed[offset + 1]) * 256 + Int64(packed[offset + 2])
        offset += 3
        if (length <= 0 || length > packed.size - offset) { throw invalidDnsSan() }
        let valueOffset = offset
        let value = Array<Byte>(length, {index => packed[valueOffset + index]})
        offset += length
        if (kind == 1) {
            try {
                dnsNames.add(String.fromUtf8(value))
            } catch (_: IllegalArgumentException) {
                throw invalidDnsSan()
            }
        } else if (kind == 2 && (length == 4 || length == 16)) {
            let family = if (length == 4) {
                IpAddressFamily.Ipv4
            } else {
                IpAddressFamily.Ipv6
            }
            ipAddresses.add(IpAddress(family, value))
        } else {
            throw invalidDnsSan()
        }
    }
    CertificateSubjectAlternativeNames(dnsNames.toArray(), ipAddresses.toArray())
}

private func verifyDns(
    names: CertificateSubjectAlternativeNames,
    host: HostName
): IdentityVerificationEvidence {
    for (pattern in names.dnsSubjectAlternativeNames()) {
        if (dnsPatternMatches(pattern, host.ascii)) {
            return IdentityVerificationEvidence(host.ascii, pattern, pattern.startsWith("*."))
        }
    }
    throw IdentityVerificationException(
        IdentityVerificationErrorCode.NoMatchingDnsSan,
        "reference DNS identity does not match any DNS subjectAltName"
    )
}

private func verifyIp(
    names: CertificateSubjectAlternativeNames,
    address: IpAddress
): IdentityVerificationEvidence {
    if (address.zone.isSome()) {
        throw IdentityVerificationException(
            IdentityVerificationErrorCode.ZonedIpReference,
            "reference IP identity cannot include an IPv6 zone"
        )
    }
    for (candidate in names.ipSubjectAlternativeNames()) {
        if (candidate == address) {
            return IdentityVerificationEvidence(ipIdentityText(address), ipIdentityText(candidate), false)
        }
    }
    throw IdentityVerificationException(
        IdentityVerificationErrorCode.NoMatchingIpSan,
        "reference IP identity does not match any IP subjectAltName"
    )
}

private func canonicalizeDnsSan(value: String): String {
    let canonical = value.toAsciiLower()
    if (canonical.startsWith("*.")) {
        let suffix = canonical[2..]
        try {
            let _ = HostName(suffix)
        } catch (_: IllegalArgumentException) {
            throw invalidDnsSan()
        }
        if (suffix.split(".").size < 2) {
            throw invalidDnsSan()
        }
        return "*.${suffix}"
    }
    if (canonical.contains("*")) {
        throw invalidDnsSan()
    }
    try {
        return HostName(canonical).ascii
    } catch (_: IllegalArgumentException) {
        throw invalidDnsSan()
    }
}

private func dnsPatternMatches(pattern: String, reference: String): Bool {
    if (!pattern.startsWith("*.")) {
        return pattern == reference
    }
    let suffix = pattern[2..]
    let referenceLabels = reference.split(".")
    let suffixLabels = suffix.split(".")
    if (referenceLabels.size != suffixLabels.size + 1) {
        return false
    }
    reference.endsWith(".${suffix}")
}

private func invalidDnsSan(): IdentityVerificationException {
    IdentityVerificationException(
        IdentityVerificationErrorCode.InvalidDnsSan,
        "DNS subjectAltName must be an ASCII A-label or a whole left-most wildcard"
    )
}

private func ipIdentityText(address: IpAddress): String {
    let prefix = match (address.family) {
        case IpAddressFamily.Ipv4 => "ipv4:"
        case IpAddressFamily.Ipv6 => "ipv6:"
    }
    let output = StringBuilder(prefix)
    for (byte in address.toOctets()) {
        output.append("${byte}.")
    }
    output.toString()
}
