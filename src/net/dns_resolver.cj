package wirestack.net

import std.collection.ArrayList
import std.convert.Parsable
import std.fs.*
import wirestack as api
import wirestack.internal.connector.HappyEyeballsConnector
import wirestack.internal.transport_stdnet.StdNetTransportFactory

/** Immutable Linux resolver settings. Configuration files must be trusted local regular files. */
public struct DnsResolverConfig {
    private let ownedNameservers: Array<api.SocketEndpoint>
    private let ownedSearchDomains: Array<api.HostName>
    /** Returns the configured DNS servers in attempt order. */
    public prop nameservers: Array<api.SocketEndpoint> { get() { ownedNameservers.clone() } }
    /** Returns the ordered search suffixes. */
    public prop searchDomains: Array<api.HostName> { get() { ownedSearchDomains.clone() } }
    /** Dot threshold for trying the unqualified name before search suffixes. */
    public let ndots: Int64
    /** Absolute hosts-file path, or an empty string to disable hosts lookup. */
    public let hostsPath: String
    /** Maximum duration of one logical lookup, including every retry and fallback. */
    public let queryTimeout: Duration
    /** Maximum passes over the configured server list. */
    public let attempts: Int64
    /** Maximum number of cached DNS entries; zero disables caching. */
    public let cacheCapacity: Int64
    /** Upper bound on positive and authoritative negative cache lifetimes. */
    public let maximumCacheTtl: Duration

    /** Creates validated settings with owned server and suffix arrays.
     * @param nameservers Up to eight nonzero-port DNS endpoints, with numeric UInt32 scope IDs when a zone is present.
     * @param searchDomains Up to sixteen search suffixes.
     * @param ndots Absolute-first threshold from zero through fifteen.
     * @param hostsPath Trusted local regular hosts file, or empty to disable.
     * @param queryTimeout Positive total lookup budget, at most five minutes.
     * @param attempts Number of server-list passes, from one through four.
     * @param cacheCapacity Cache entry bound, from zero through 4096.
     * @param maximumCacheTtl Maximum retained TTL, from zero through one day.
     */
    public init(
        nameservers!: Array<api.SocketEndpoint> = Array<api.SocketEndpoint>(),
        searchDomains!: Array<api.HostName> = Array<api.HostName>(),
        ndots!: Int64 = 1,
        hostsPath!: String = "/etc/hosts",
        queryTimeout!: Duration = 5 * Duration.second,
        attempts!: Int64 = 2,
        cacheCapacity!: Int64 = 256,
        maximumCacheTtl!: Duration = 300 * Duration.second
    ) {
        if (nameservers.size > 8 || searchDomains.size > 16 || ndots < 0 || ndots > 15 ||
            hostsPath.size > 4096 || hostsPath.contains("\0") ||
            (!hostsPath.isEmpty() && !Path(hostsPath).isAbsolute()) ||
            queryTimeout <= Duration.Zero || queryTimeout > 300 * Duration.second ||
            attempts < 1 || attempts > 4 || cacheCapacity < 0 || cacheCapacity > 4096 ||
            maximumCacheTtl < Duration.Zero || maximumCacheTtl > 86400 * Duration.second) {
            throw IllegalArgumentException("DNS resolver settings exceed their bounds")
        }
        let servers = nameservers.clone()
        for (index in 0..servers.size) {
            servers[index] = canonicalDnsNameserver(servers[index])
        }
        ownedNameservers = servers
        ownedSearchDomains = searchDomains.clone()
        this.ndots = ndots
        this.hostsPath = hostsPath
        this.queryTimeout = queryTimeout
        this.attempts = attempts
        this.cacheCapacity = cacheCapacity
        this.maximumCacheTtl = maximumCacheTtl
    }

    internal func sameSettings(other: DnsResolverConfig): Bool {
        queryTimeout == other.queryTimeout && attempts == other.attempts &&
            cacheCapacity == other.cacheCapacity && maximumCacheTtl == other.maximumCacheTtl &&
            ndots == other.ndots && hostsPath == other.hostsPath &&
            ownedNameservers == other.ownedNameservers && ownedSearchDomains == other.ownedSearchDomains
    }

    /** Reads bounded nameserver, search/domain and ndots settings.
     * Missing, unreadable, nonregular, oversized or non-UTF-8 files yield default settings.
     * Unknown directives and invalid entries are ignored. The last search/domain directive wins.
     * Nameserver zones must be numeric UInt32 scope IDs supported by the Linux adapter.
     * @param path Absolute path to a trusted local regular resolv.conf file.
     */
    public static func fromSystem(path!: String = "/etc/resolv.conf"): DnsResolverConfig {
        let contents = readDnsConfiguration(path)
        let servers = ArrayList<api.SocketEndpoint>()
        let search = ArrayList<api.HostName>()
        var dots: Int64 = 1
        for (line in contents.split("\n")) {
            let fields = dnsConfigurationFields(line)
            if (fields.isEmpty()) { continue }
            match (fields[0]) {
                case "nameserver" =>
                    if (fields.size >= 2 && servers.size < 8) {
                        if (let Some(address) <- parseDnsIpLiteral(fields[1])) {
                            try {
                                let endpoint = canonicalDnsNameserver(api.SocketEndpoint(address, 53))
                                var duplicate = false
                                for (existing in servers) {
                                    if (existing == endpoint) { duplicate = true; break }
                                }
                                if (!duplicate) { servers.add(endpoint) }
                            } catch (_: IllegalArgumentException) { () }
                        }
                    }
                case "search" | "domain" =>
                    search.clear()
                    for (index in 1..fields.size) {
                        if (search.size >= 16 || (fields[0] == "domain" && index > 1)) { break }
                        try {
                            let suffix = api.HostName(fields[index])
                            var duplicate = false
                            for (existing in search) { if (existing == suffix) { duplicate = true } }
                            if (!duplicate) { search.add(suffix) }
                        } catch (_: IllegalArgumentException) { () }
                    }
                case "options" =>
                    for (field in fields) {
                        if (field.startsWith("ndots:")) {
                            if (let Some(value) <- Int64.tryParse(field[6..field.size])) {
                                if (value >= 0) { dots = if (value > 15) { 15 } else { value } }
                            }
                        }
                    }
                case _ => ()
            }
        }
        DnsResolverConfig(nameservers: servers.toArray(), searchDomains: search.toArray(), ndots: dots)
    }
}

private func canonicalDnsNameserver(server: api.SocketEndpoint): api.SocketEndpoint {
    if (server.port == 0) { throw IllegalArgumentException("DNS server port must be nonzero") }
    let address = canonicalDnsIpAddress(server.address)
    if (address.zone == server.address.zone) { server } else { api.SocketEndpoint(address, server.port) }
}

private func canonicalDnsIpAddress(address: api.IpAddress): api.IpAddress {
    if (let Some(zone) <- address.zone) {
        let scope = match (UInt32.tryParse(zone)) {
            case Some(value) => value
            case None => throw IllegalArgumentException("DNS address zones must be numeric UInt32 scope IDs")
        }
        let canonical = if (scope == 0u32) { None<String> } else { Some(scope.toString()) }
        if (canonical != address.zone) {
            return api.IpAddress(address.family, address.toOctets(), zone: canonical)
        }
    }
    address
}

internal func checkDnsContext(context: api.OperationContext): Unit {
    if (context.isCancellationRequested()) {
        throw api.ResolveException(api.ResolveErrorCode.Cancelled, "DNS operation cancelled")
    }
    if (context.isDeadlineExceeded()) {
        throw api.ResolveException(api.ResolveErrorCode.Timeout, "DNS operation deadline exceeded")
    }
}

private func readDnsConfiguration(path: String): String {
    if (path.isEmpty()) { return "" }
    if (path.size > 4096 || path.contains("\0") || !Path(path).isAbsolute()) {
        throw IllegalArgumentException("DNS configuration path must be absolute and bounded")
    }
    try {
        let before = FileInfo(path)
        if (!before.isRegular() || before.size < 0 || before.size > 1024 * 1024) { return "" }
        let file = File(path, OpenMode.Read)
        try {
            if (!file.info.isRegular()) { return "" }
            let bytes = ArrayList<Byte>()
            let buffer = Array<Byte>(4096, repeat: 0u8)
            var lines: Int64 = 0
            while (true) {
                let count = file.read(buffer)
                if (count == 0) { break }
                if (count < 0 || count > buffer.size || bytes.size + count > 1024 * 1024) { return "" }
                for (index in 0..count) {
                    if (buffer[index] == b'\n') {
                        lines += 1
                        if (lines > 4096) { return "" }
                    }
                    bytes.add(buffer[index])
                }
            }
            try { String.fromUtf8(bytes.toArray()) } catch (_: Exception) { "" }
        } finally { file.close() }
    } catch (_: FSException) { "" }
}

private func dnsConfigurationFields(line: String): Array<String> {
    let bytes = line.toArray()
    let fields = ArrayList<String>()
    var start: Int64 = -1
    for (index in 0..bytes.size) {
        let value = bytes[index]
        if (value == b'#' || value == b';') {
            if (start >= 0) { fields.add(line[start..index]) }
            return fields.toArray()
        }
        if (value == b' ' || value == b'\t' || value == b'\r') {
            if (start >= 0) { fields.add(line[start..index]); start = -1 }
        } else if (start < 0) { start = index }
        if (fields.size >= 128) { return fields.toArray() }
    }
    if (start >= 0) { fields.add(line[start..line.size]) }
    fields.toArray()
}

private func parseDnsIpv4(value: String): ?api.IpAddress {
    let parts = value.split(".")
    if (parts.size != 4) { return None<api.IpAddress> }
    let octets = Array<Byte>(4, repeat: 0u8)
    for (index in 0..4) {
        let part = parts[index].toArray()
        if (part.isEmpty() || part.size > 3 || (part.size > 1 && part[0] == b'0')) {
            return None<api.IpAddress>
        }
        var number: Int64 = 0
        for (digit in part) {
            if (digit < b'0' || digit > b'9') { return None<api.IpAddress> }
            number = number * 10 + Int64(digit - b'0')
        }
        if (number > 255) { return None<api.IpAddress> }
        octets[index] = UInt8(number)
    }
    Some(api.IpAddress(api.IpAddressFamily.Ipv4, octets))
}

private func parseDnsIpLiteral(value: String): ?api.IpAddress {
    if (value.isEmpty() || value.size > 128) { return None<api.IpAddress> }
    if (!value.contains(":")) { return parseDnsIpv4(value) }
    let zoned = value.split("%")
    if (zoned.size > 2) { return None<api.IpAddress> }
    let zone = if (zoned.size == 2) { Some(zoned[1]) } else { None<String> }
    if (let Some(name) <- zone) {
        if (name.isEmpty() || name.size > 64) { return None<api.IpAddress> }
        for (c in name.toArray()) {
            if (!((c >= b'a' && c <= b'z') || (c >= b'A' && c <= b'Z') ||
                (c >= b'0' && c <= b'9') || c == b'_' || c == b'-' || c == b'.')) {
                return None<api.IpAddress>
            }
        }
    }
    let halves = zoned[0].split("::")
    if (halves.size > 2) { return None<api.IpAddress> }
    let left = ArrayList<UInt16>()
    let right = ArrayList<UInt16>()
    for (side in 0..halves.size) {
        if (halves[side].isEmpty()) { continue }
        let groups = halves[side].split(":")
        for (index in 0..groups.size) {
            let group = groups[index]
            let destination = if (side == 0) { left } else { right }
            if (group.contains(".")) {
                if (side != halves.size - 1 || index != groups.size - 1) { return None<api.IpAddress> }
                match (parseDnsIpv4(group)) {
                    case Some(address) =>
                        let bytes = address.toOctets()
                        destination.add((UInt16(bytes[0]) << 8) | UInt16(bytes[1]))
                        destination.add((UInt16(bytes[2]) << 8) | UInt16(bytes[3]))
                    case None => return None<api.IpAddress>
                }
            } else {
                if (group.isEmpty() || group.size > 4) { return None<api.IpAddress> }
                var number: UInt16 = 0
                for (digit in group.toArray()) {
                    let nibble = if (digit >= b'0' && digit <= b'9') { Int64(digit - b'0') }
                        else if (digit >= b'a' && digit <= b'f') { Int64(digit - b'a') + 10 }
                        else if (digit >= b'A' && digit <= b'F') { Int64(digit - b'A') + 10 }
                        else { -1 }
                    if (nibble < 0) { return None<api.IpAddress> }
                    number = (number << 4) | UInt16(nibble)
                }
                destination.add(number)
            }
        }
    }
    let count = left.size + right.size
    if ((halves.size == 1 && count != 8) || (halves.size == 2 && count >= 8)) {
        return None<api.IpAddress>
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
    Some(api.IpAddress(api.IpAddressFamily.Ipv6, bytes, zone: zone))
}

/** Hosts-first resolver implementing the transport-neutral resolver contract.
 * The hosts file is snapshotted at construction. Construct a new resolver to reload it.
 * HostName has already discarded a trailing root dot; use the String overload for absolute names.
 */
public class Resolver <: api.Resolver & Resource {
    private let dns: DnsClient
    private let hosts: Array<DnsHostsEntry>
    /** Immutable settings used for search ordering and the total lookup budget. */
    public let config: DnsResolverConfig

    /** Captures hosts entries and creates or adopts a DNS client.
     * Closing this resolver also closes an explicitly supplied client.
     * An adopted client must have equivalent settings; mismatch is rejected before ownership transfer.
     * @param config Settings for hosts, search and DNS policy.
     * @param dns Optional matching client whose ownership transfers to this resolver.
     */
    public init(config!: DnsResolverConfig = DnsResolverConfig.fromSystem(),
        dns!: ?DnsClient = None<DnsClient>) {
        if (let Some(client) <- dns) {
            if (!config.sameSettings(client.config)) {
                throw IllegalArgumentException("adopted DNS client settings must match resolver settings")
            }
        }
        this.config = config
        hosts = snapshotDnsHosts(config.hostsPath)
        this.dns = match (dns) {
            case Some(client) => client
            case None => DnsClient(config: config)
        }
    }

    /** Resolves and connects using the existing bounded Happy Eyeballs scheduler.
     * DNS and all TCP candidates share one absolute deadline. The returned transport
     * belongs to the caller; closing this resolver does not close established connections.
     * @param host Canonical DNS host.
     * @param port Numeric TCP destination port.
     * @param options Address-family and candidate-count limits.
     * @param attemptDelay Delay between scheduled connection candidates.
     * @param context Cancellation, trace and absolute budget for DNS and TCP.
     */
    public func connect(host: api.HostName, port: UInt16,
        options!: api.ResolveOptions = api.ResolveOptions(),
        attemptDelay!: Duration = 250 * Duration.millisecond,
        context!: api.OperationContext = api.OperationContext.background()): api.DuplexTransport {
        requireReady(context)
        HappyEyeballsConnector(this, StdNetTransportFactory(), attemptDelay: attemptDelay)
            .connect(host, port, options: options, context: context).transport
    }

    /** Resolves an IPv4 literal directly, or a DNS host through hosts/search/DNS policy.
     * @param host Canonical DNS host or dotted IPv4 literal.
     * @param options Requested address family and result bound.
     * @param context Shared cancellation and absolute deadline.
     */
    public func resolve(host: api.HostName, options!: api.ResolveOptions = api.ResolveOptions(),
        context!: api.OperationContext = api.OperationContext.background()): api.ResolveResult {
        resolveName(host, false, options, context)
    }

    /** Resolves an IPv4 literal or DNS name, preserving an explicit trailing root dot.
     * @param name Dotted IPv4 literal or ASCII DNS name; a trailing dot disables search expansion.
     * @param options Requested address family and result bound.
     * @param context Shared cancellation and absolute deadline.
     */
    public func resolve(name: String, options!: api.ResolveOptions = api.ResolveOptions(),
        context!: api.OperationContext = api.OperationContext.background()): api.ResolveResult {
        requireReady(context)
        resolveName(api.HostName(name), name.endsWith("."), options, context)
    }

    /** Implements the resolver used by existing HTTP and Happy Eyeballs pipelines.
     * This address-only resolver does not resolve service names.
     * @param host Canonical DNS host or dotted IPv4 literal.
     * @param service Must be absent; the connector supplies its numeric port separately.
     * @param options Requested address family and result bound.
     * @param context Shared cancellation and absolute deadline.
     */
    public func resolve(host: api.HostName, service: ?String, options: api.ResolveOptions,
        context: api.OperationContext): api.ResolveResult {
        requireReady(context)
        if (service.isSome()) {
            throw api.ResolveException(api.ResolveErrorCode.InvalidName,
                "DNS address resolution does not accept a service name")
        }
        resolveName(host, false, options, context)
    }

    /** Stops DNS admission and joins client-owned DNS cleanup.
     * Connections already handed to a connector or caller are not owned by the resolver.
     */
    public func close(): Unit { dns.close() }
    /** Reports whether the owned DNS client is closed. */
    public func isClosed(): Bool { dns.isClosed() }

    private func requireReady(context: api.OperationContext): Unit {
        checkDnsContext(context)
        if (dns.isClosed()) {
            throw api.ResolveException(api.ResolveErrorCode.Cancelled, "resolver is closed")
        }
    }

    private func resolveName(host: api.HostName, absolute: Bool, options: api.ResolveOptions,
        context: api.OperationContext): api.ResolveResult {
        requireReady(context)
        let bounded = context.shortenDeadline(config.queryTimeout)
        if (let Some(literal) <- parseDnsIpv4(host.ascii)) {
            requireReady(bounded)
            if (!dnsPolicyFamilyMatches(literal, options.family)) {
                throw api.ResolveException(api.ResolveErrorCode.NoData,
                    "IPv4 literal does not match the requested address family")
            }
            return api.ResolveResult([literal], host, api.ResolverSource.Static)
        }
        let addresses = ArrayList<api.IpAddress>()
        for (entry in hosts) {
            requireReady(bounded)
            if (entry.name == host && dnsPolicyFamilyMatches(entry.address, options.family) &&
                addresses.size < options.maxResults) {
                var duplicate = false
                for (address in addresses) { if (address == entry.address) { duplicate = true } }
                if (!duplicate) { addresses.add(entry.address) }
            }
        }
        if (!addresses.isEmpty()) {
            requireReady(bounded)
            return api.ResolveResult(addresses.toArray(), host, api.ResolverSource.HostsFile)
        }
        var dots: Int64 = 0
        for (byte in host.ascii.toArray()) { if (byte == b'.') { dots += 1 } }
        let candidates = ArrayList<api.HostName>()
        if (absolute || dots >= config.ndots) { candidates.add(host) }
        if (!absolute) {
            // Reserve the original-name slot only when it has not been inserted.
            let candidateLimit: Int64 = if (candidates.isEmpty()) { 15 } else { 16 }
            for (suffix in config.searchDomains) {
                if (candidates.size >= candidateLimit) { break }
                try {
                    let candidate = api.HostName("${host.ascii}.${suffix.ascii}")
                    var duplicate = false
                    for (existing in candidates) { if (existing == candidate) { duplicate = true } }
                    if (!duplicate) { candidates.add(candidate) }
                } catch (_: IllegalArgumentException) { () }
            }
            var originalPresent = false
            for (candidate in candidates) { if (candidate == host) { originalPresent = true } }
            if (!originalPresent) { candidates.add(host) }
        }
        var last: ?api.ResolveException = None<api.ResolveException>
        for (candidate in candidates) {
            requireReady(bounded)
            try {
                let result = dns.lookup(candidate, options: options, context: bounded)
                requireReady(bounded)
                return result
            } catch (error: api.ResolveException) {
                match (error.resolveCode) {
                    case api.ResolveErrorCode.NameNotFound | api.ResolveErrorCode.NoData => last = Some(error)
                    case _ => throw error
                }
            }
        }
        requireReady(bounded)
        match (last) {
            case Some(error) => throw error
            case None => throw api.ResolveException(api.ResolveErrorCode.NameNotFound,
                "resolver exhausted its search candidates")
        }
    }
}

private struct DnsHostsEntry {
    let name: api.HostName
    let address: api.IpAddress
    init(name: api.HostName, address: api.IpAddress) { this.name = name; this.address = address }
}

private func snapshotDnsHosts(path: String): Array<DnsHostsEntry> {
    let entries = ArrayList<DnsHostsEntry>()
    for (line in readDnsConfiguration(path).split("\n")) {
        let fields = dnsConfigurationFields(line)
        if (fields.size < 2) { continue }
        if (let Some(address) <- parseDnsIpLiteral(fields[0])) {
            let canonical = try { canonicalDnsIpAddress(address) }
                catch (_: IllegalArgumentException) { continue }
            for (index in 1..fields.size) {
                if (entries.size >= 4096) { return entries.toArray() }
                try { entries.add(DnsHostsEntry(api.HostName(fields[index]), canonical)) }
                catch (_: IllegalArgumentException) { () }
            }
        }
    }
    entries.toArray()
}

private func dnsPolicyFamilyMatches(address: api.IpAddress, family: api.ResolveAddressFamily): Bool {
    match (family) {
        case api.ResolveAddressFamily.Any => true
        case api.ResolveAddressFamily.Ipv4 => address.family == api.IpAddressFamily.Ipv4
        case api.ResolveAddressFamily.Ipv6 => address.family == api.IpAddressFamily.Ipv6
    }
}
