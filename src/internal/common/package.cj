package wirestack.internal.common

public enum IpAddressFamily {
    | Ipv4
    | Ipv6
}

/** A DNS-free IP address value used at transport boundaries. */
public struct IpAddress {
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
}

/** An already-resolved IP endpoint. Construction never performs DNS. */
public struct SocketEndpoint {
    public let address: IpAddress
    public let port: UInt16

    public init(address: IpAddress, port: UInt16) {
        this.address = address
        this.port = port
    }
}
