package wirestack

import std.collection.ArrayList

/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
public enum IpAddressFamily <: Equatable<IpAddressFamily> {
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | Ipv4
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | Ipv6

/**
 * Wirestack 公开 API：比较两个值是否相等。
 * @param other 用于比较的另一个值。
 */
    public operator func ==(other: IpAddressFamily): Bool {
        match ((this, other)) {
            case (IpAddressFamily.Ipv4, IpAddressFamily.Ipv4) => true
            case (IpAddressFamily.Ipv6, IpAddressFamily.Ipv6) => true
            case _ => false
        }
    }

/**
 * Wirestack 公开 API：比较两个值是否不同。
 * @param other 用于比较的另一个值。
 */
    public operator func !=(other: IpAddressFamily): Bool {
        !(this == other)
    }
}

/** A DNS-free IP address value used at transport boundaries. */
public struct IpAddress <: Equatable<IpAddress> & Hashable {
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let family: IpAddressFamily
    private let octets: Array<Byte>
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let zone: ?String

/**
 * Wirestack 公开 API：构造并校验该公开值。
 * @param family 地址使用的 IP 地址族。
 * @param octets 保存地址内容的字节序列。
 * @param zone IPv6 链路本地地址的区域标识。
 */
    public init(family: IpAddressFamily, octets: Array<Byte>, zone!: ?String = None<String>) {
        let expected = match (family) {
            case IpAddressFamily.Ipv4 => 4
            case IpAddressFamily.Ipv6 => 16
        }
        if (octets.size != expected) {
            let familyName = match (family) {
                case IpAddressFamily.Ipv4 => "IPv4"
                case IpAddressFamily.Ipv6 => "IPv6"
            }
            throw IllegalArgumentException("${familyName} address requires ${expected} octets")
        }
        match (family) {
            case IpAddressFamily.Ipv4 =>
                if (zone.isSome()) {
                    throw IllegalArgumentException("IPv4 addresses cannot carry an IPv6 zone")
                }
            case IpAddressFamily.Ipv6 => ()
        }
        if (let Some(value) <- zone) {
            if (value.isEmpty() || value.size > 64) {
                throw IllegalArgumentException("IPv6 zone must contain 1 to 64 bytes")
            }
        }
        this.family = family
        this.octets = octets.clone()
        this.zone = zone
    }

    /** Returns a defensive copy so address identity cannot be mutated. */
    public func toOctets(): Array<Byte> {
        octets.clone()
    }

/**
 * Wirestack 公开 API：比较两个值是否相等。
 * @param other 用于比较的另一个值。
 */
    public operator func ==(other: IpAddress): Bool {
        family == other.family && octets == other.octets && zone == other.zone
    }

/**
 * Wirestack 公开 API：比较两个值是否不同。
 * @param other 用于比较的另一个值。
 */
    public operator func !=(other: IpAddress): Bool {
        !(this == other)
    }

/**
 * Wirestack 公开 API：返回用于哈希容器的稳定哈希值。
 */
    public func hashCode(): Int64 {
        var hasher = DefaultHasher()
        match (family) {
            case IpAddressFamily.Ipv4 => hasher.write(4u8)
            case IpAddressFamily.Ipv6 => hasher.write(6u8)
        }
        for (octet in octets) {
            hasher.write(octet)
        }
        if (let Some(value) <- zone) {
            hasher.write(value)
        }
        hasher.finish()
    }
}

/** An already-resolved IP endpoint. Construction never performs DNS. */
public struct SocketEndpoint <: Equatable<SocketEndpoint> & Hashable {
/**
 * Wirestack 公开 API：更新当前构建器或集合的受约束状态。
 */
    public let address: IpAddress
/**
 * Wirestack 公开 API：返回当前对象保存的受约束值。
 */
    public let port: UInt16

/**
 * Wirestack 公开 API：构造并校验该公开值。
 * @param address 目标或本地网络地址。
 * @param port 目标服务端口号。
 */
    public init(address: IpAddress, port: UInt16) {
        this.address = address
        this.port = port
    }

/**
 * Wirestack 公开 API：比较两个值是否相等。
 * @param other 用于比较的另一个值。
 */
    public operator func ==(other: SocketEndpoint): Bool {
        address == other.address && port == other.port
    }

/**
 * Wirestack 公开 API：比较两个值是否不同。
 * @param other 用于比较的另一个值。
 */
    public operator func !=(other: SocketEndpoint): Bool {
        !(this == other)
    }

/**
 * Wirestack 公开 API：返回用于哈希容器的稳定哈希值。
 */
    public func hashCode(): Int64 {
        var hasher = DefaultHasher()
        hasher.write(address.hashCode())
        hasher.write(port)
        hasher.finish()
    }
}

/** Canonical ASCII DNS name. Construction performs validation, never DNS. */
public struct HostName <: Equatable<HostName> & Hashable & ToString {
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let ascii: String

/**
 * Wirestack 公开 API：构造并校验该公开值。
 * @param value 待写入或配置的值。
 */
    public init(value: String) {
        if (value.isEmpty()) {
            throw IllegalArgumentException("host name must not be empty")
        }
        let bytes = value.toArray()
        let withoutRoot = if (bytes.size > 1 && bytes[bytes.size - 1] == b'.') {
            value[..value.size - 1]
        } else {
            value
        }
        if (withoutRoot.isEmpty() || withoutRoot.size > 253) {
            throw IllegalArgumentException("host name must contain 1 to 253 ASCII bytes")
        }
        let canonical = withoutRoot.toAsciiLower()
        let labels = canonical.split(".")
        for (label in labels) {
            validateDnsLabel(label)
        }
        ascii = canonical
    }

/**
 * Wirestack 公开 API：比较两个值是否相等。
 * @param other 用于比较的另一个值。
 */
    public operator func ==(other: HostName): Bool {
        ascii == other.ascii
    }

/**
 * Wirestack 公开 API：比较两个值是否不同。
 * @param other 用于比较的另一个值。
 */
    public operator func !=(other: HostName): Bool {
        ascii != other.ascii
    }

/**
 * Wirestack 公开 API：返回用于哈希容器的稳定哈希值。
 */
    public func hashCode(): Int64 {
        ascii.hashCode()
    }

/**
 * Wirestack 公开 API：返回适合日志和诊断的文本表示。
 */
    public func toString(): String {
        ascii
    }
}

private func validateDnsLabel(label: String): Unit {
    let bytes = label.toArray()
    if (bytes.isEmpty() || bytes.size > 63) {
        throw IllegalArgumentException("DNS labels must contain 1 to 63 bytes")
    }
    if (!isAsciiAlphaNumeric(bytes[0]) || !isAsciiAlphaNumeric(bytes[bytes.size - 1])) {
        throw IllegalArgumentException("DNS labels must start and end with an ASCII letter or digit")
    }
    for (value in bytes) {
        if (!isAsciiAlphaNumeric(value) && value != b'-') {
            throw IllegalArgumentException("host name contains a non-ASCII or unsupported character")
        }
    }
}

private func isAsciiAlphaNumeric(value: Byte): Bool {
    (value >= b'a' && value <= b'z') ||
        (value >= b'A' && value <= b'Z') ||
        (value >= b'0' && value <= b'9')
}

private func parseIpv4AddressLiteral(value: String): ?IpAddress {
    let parts = value.split(".")
    if (parts.size != 4) { return None<IpAddress> }
    let octets = Array<Byte>(4, repeat: 0u8)
    for (index in 0..4) {
        let part = parts[index].toArray()
        if (part.isEmpty() || part.size > 3 || (part.size > 1 && part[0] == b'0')) {
            return None<IpAddress>
        }
        var number: Int64 = 0
        for (digit in part) {
            if (digit < b'0' || digit > b'9') { return None<IpAddress> }
            number = number * 10 + Int64(digit - b'0')
        }
        if (number > 255) { return None<IpAddress> }
        octets[index] = UInt8(number)
    }
    Some(IpAddress(IpAddressFamily.Ipv4, octets))
}

internal func parseIpAddressLiteral(value: String): ?IpAddress {
    if (value.isEmpty() || value.size > 128) { return None<IpAddress> }
    if (!value.contains(":")) { return parseIpv4AddressLiteral(value) }
    let zoned = value.split("%")
    if (zoned.size > 2) { return None<IpAddress> }
    let zone = if (zoned.size == 2) { Some(zoned[1]) } else { None<String> }
    if (let Some(name) <- zone) {
        if (name.isEmpty() || name.size > 64) { return None<IpAddress> }
        for (c in name.toArray()) {
            if (!((c >= b'a' && c <= b'z') || (c >= b'A' && c <= b'Z') ||
                (c >= b'0' && c <= b'9') || c == b'_' || c == b'-' || c == b'.')) {
                return None<IpAddress>
            }
        }
    }
    let halves = zoned[0].split("::")
    if (halves.size > 2) { return None<IpAddress> }
    let left = ArrayList<UInt16>()
    let right = ArrayList<UInt16>()
    for (side in 0..halves.size) {
        if (halves[side].isEmpty()) { continue }
        let groups = halves[side].split(":")
        for (index in 0..groups.size) {
            let group = groups[index]
            let destination = if (side == 0) { left } else { right }
            if (group.contains(".")) {
                if (side != halves.size - 1 || index != groups.size - 1) { return None<IpAddress> }
                match (parseIpv4AddressLiteral(group)) {
                    case Some(address) =>
                        let bytes = address.toOctets()
                        destination.add((UInt16(bytes[0]) << 8) | UInt16(bytes[1]))
                        destination.add((UInt16(bytes[2]) << 8) | UInt16(bytes[3]))
                    case None => return None<IpAddress>
                }
            } else {
                if (group.isEmpty() || group.size > 4) { return None<IpAddress> }
                var number: UInt16 = 0
                for (digit in group.toArray()) {
                    let nibble = if (digit >= b'0' && digit <= b'9') { Int64(digit - b'0') }
                        else if (digit >= b'a' && digit <= b'f') { Int64(digit - b'a') + 10 }
                        else if (digit >= b'A' && digit <= b'F') { Int64(digit - b'A') + 10 }
                        else { -1 }
                    if (nibble < 0) { return None<IpAddress> }
                    number = (number << 4) | UInt16(nibble)
                }
                destination.add(number)
            }
        }
    }
    let count = left.size + right.size
    if ((halves.size == 1 && count != 8) || (halves.size == 2 && count >= 8)) {
        return None<IpAddress>
    }
    let bytes = Array<Byte>(16, repeat: 0u8)
    for (index in 0..left.size) {
        bytes[index * 2] = UInt8(left[index] >> 8)
        bytes[index * 2 + 1] = UInt8(left[index] & 255u16)
    }
    for (index in 0..right.size) {
        let offset = (8 - right.size + index) * 2
        bytes[offset] = UInt8(right[index] >> 8)
        bytes[offset + 1] = UInt8(right[index] & 255u16)
    }
    Some(IpAddress(IpAddressFamily.Ipv6, bytes, zone: zone))
}
