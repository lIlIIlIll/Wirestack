package wirestack.internal.common

public enum IpAddressFamily <: Equatable<IpAddressFamily> {
    | Ipv4
    | Ipv6

    public operator func ==(other: IpAddressFamily): Bool {
        match ((this, other)) {
            case (IpAddressFamily.Ipv4, IpAddressFamily.Ipv4) => true
            case (IpAddressFamily.Ipv6, IpAddressFamily.Ipv6) => true
            case _ => false
        }
    }

    public operator func !=(other: IpAddressFamily): Bool {
        !(this == other)
    }
}

/** A DNS-free IP address value used at transport boundaries. */
public struct IpAddress <: Equatable<IpAddress> & Hashable {
    public let family: IpAddressFamily
    private let octets: Array<Byte>
    public let zone: ?String

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

    public operator func ==(other: IpAddress): Bool {
        family == other.family && octets == other.octets && zone == other.zone
    }

    public operator func !=(other: IpAddress): Bool {
        !(this == other)
    }

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
    public let address: IpAddress
    public let port: UInt16

    public init(address: IpAddress, port: UInt16) {
        this.address = address
        this.port = port
    }

    public operator func ==(other: SocketEndpoint): Bool {
        address == other.address && port == other.port
    }

    public operator func !=(other: SocketEndpoint): Bool {
        !(this == other)
    }

    public func hashCode(): Int64 {
        var hasher = DefaultHasher()
        hasher.write(address.hashCode())
        hasher.write(port)
        hasher.finish()
    }
}

/** Canonical ASCII DNS name. Construction performs validation, never DNS. */
public struct HostName <: Equatable<HostName> & Hashable & ToString {
    public let ascii: String

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

    public operator func ==(other: HostName): Bool {
        ascii == other.ascii
    }

    public operator func !=(other: HostName): Bool {
        ascii != other.ascii
    }

    public func hashCode(): Int64 {
        ascii.hashCode()
    }

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
