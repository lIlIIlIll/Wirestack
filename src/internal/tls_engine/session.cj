package wirestack.internal.tls_engine

import std.collection.*
import std.sync.*
import std.time.*
import wirestack.internal.common.*
import wirestack.internal.platform.linux.*
import wirestack.internal.transport.*
import wirestack.internal.trust.*

private let DEFAULT_MAXIMUM_SESSION_ENTRIES: Int64 = 256
private let DEFAULT_MAXIMUM_SESSION_BYTES: Int64 = 4 * 1024 * 1024
private let DEFAULT_MAXIMUM_ONE_SESSION_BYTES: Int64 = 256 * 1024

/** Non-secret partition key for one resumable TLS security context. */
public struct TlsSessionKey {
    public let serverIdentity: String
    public let alpnContext: String
    public let trustContextIdentity: String
    public let clientIdentity: String
    public let providerIdentity: String
    public let securityContext: String

    internal init(
        serverIdentity: String,
        alpnContext: String,
        trustContextIdentity: String,
        clientIdentity: String,
        providerIdentity: String,
        securityContext: String
    ) {
        this.serverIdentity = serverIdentity
        this.alpnContext = alpnContext
        this.trustContextIdentity = trustContextIdentity
        this.clientIdentity = clientIdentity
        this.providerIdentity = providerIdentity
        this.securityContext = securityContext
    }

    internal func sameAs(other: TlsSessionKey): Bool {
        serverIdentity == other.serverIdentity &&
            alpnContext == other.alpnContext &&
            trustContextIdentity == other.trustContextIdentity &&
            clientIdentity == other.clientIdentity &&
            providerIdentity == other.providerIdentity &&
            securityContext == other.securityContext
    }
}

/** Secret-free bounded-store diagnostics. */
public struct TlsSessionStoreSnapshot {
    public let entries: Int64
    public let encodedBytes: Int64
    public let maximumEntries: Int64
    public let maximumEncodedBytes: Int64

    internal init(entries: Int64, bytes: Int64, maximumEntries: Int64, maximumBytes: Int64) {
        this.entries = entries
        encodedBytes = bytes
        this.maximumEntries = maximumEntries
        maximumEncodedBytes = maximumBytes
    }
}

private class TlsSessionEntry {
    let key: TlsSessionKey
    let expiresAt: MonoTime
    let singleUse: Bool
    var encoded: Array<Byte>

    init(key: TlsSessionKey, expiresAt: MonoTime, singleUse: Bool, encoded: Array<Byte>) {
        this.key = key
        this.expiresAt = expiresAt
        this.singleUse = singleUse
        this.encoded = encoded
    }

    func clear(): Unit {
        clearSessionBytes(encoded)
        encoded = Array<Byte>()
    }
}

/** Thread-safe LRU session store with hard entry, per-session and total-byte ceilings. */
public class TlsSessionStore <: Resource {
    private let mutex = Mutex()
    private let clock: MonotonicClock
    private let maximumEntries: Int64
    private let maximumBytes: Int64
    private let maximumSessionBytes: Int64
    private var entries = ArrayList<TlsSessionEntry>()
    private var encodedBytes: Int64 = 0
    private var closed = false

    public init(
        maximumEntries!: Int64 = DEFAULT_MAXIMUM_SESSION_ENTRIES,
        maximumEncodedBytes!: Int64 = DEFAULT_MAXIMUM_SESSION_BYTES,
        maximumOneSessionBytes!: Int64 = DEFAULT_MAXIMUM_ONE_SESSION_BYTES,
        clock!: MonotonicClock = SystemMonotonicClock()
    ) {
        if (maximumEntries <= 0 || maximumEntries > 4096 ||
            maximumEncodedBytes <= 0 || maximumEncodedBytes > 64 * 1024 * 1024 ||
            maximumOneSessionBytes <= 0 || maximumOneSessionBytes > 1024 * 1024 ||
            maximumOneSessionBytes > maximumEncodedBytes) {
            throw IllegalArgumentException("TLS session store limits are invalid")
        }
        this.maximumEntries = maximumEntries
        maximumBytes = maximumEncodedBytes
        maximumSessionBytes = maximumOneSessionBytes
        this.clock = clock
    }

    internal func put(
        key: TlsSessionKey,
        encoded: Array<Byte>,
        lifetimeSeconds: UInt64,
        singleUse: Bool
    ): Unit {
        if (encoded.isEmpty() || encoded.size > maximumSessionBytes || lifetimeSeconds == 0u64) {
            clearSessionBytes(encoded)
            return
        }
        synchronized(mutex) {
            if (closed) {
                clearSessionBytes(encoded)
                return
            }
            purgeExpired(clock.now())
            removeMatching(key)
            let owned = encoded.clone()
            clearSessionBytes(encoded)
            entries.add(TlsSessionEntry(
                key,
                clock.now() + Int64(lifetimeSeconds) * Duration.second,
                singleUse,
                owned
            ))
            encodedBytes += owned.size
            while (entries.size > maximumEntries || encodedBytes > maximumBytes) {
                removeAt(0)
            }
        }
    }

    internal func take(key: TlsSessionKey): ?Array<Byte> {
        synchronized(mutex) {
            if (closed) {
                return None<Array<Byte>>
            }
            purgeExpired(clock.now())
            for (index in 0..entries.size) {
                let entry = entries[index]
                if (entry.key.sameAs(key)) {
                    let output = entry.encoded.clone()
                    if (entry.singleUse) {
                        removeAt(index)
                    } else {
                        let retained = entries.remove(at: index)
                        entries.add(retained)
                    }
                    return Some(output)
                }
            }
            None<Array<Byte>>
        }
    }

    public func snapshot(): TlsSessionStoreSnapshot {
        synchronized(mutex) {
            if (!closed) {
                purgeExpired(clock.now())
            }
            TlsSessionStoreSnapshot(entries.size, encodedBytes, maximumEntries, maximumBytes)
        }
    }

    public func close(): Unit {
        synchronized(mutex) {
            if (!closed) {
                while (!entries.isEmpty()) { removeAt(entries.size - 1) }
                closed = true
            }
        }
    }

    public func isClosed(): Bool {
        synchronized(mutex) { closed }
    }

    private func purgeExpired(now: MonoTime): Unit {
        var index: Int64 = 0
        while (index < entries.size) {
            if (now >= entries[index].expiresAt) {
                removeAt(index)
            } else {
                index++
            }
        }
    }

    private func removeMatching(key: TlsSessionKey): Unit {
        var index: Int64 = 0
        while (index < entries.size) {
            if (entries[index].key.sameAs(key)) {
                removeAt(index)
            } else {
                index++
            }
        }
    }

    private func removeAt(index: Int64): Unit {
        let removed = entries.remove(at: index)
        encodedBytes -= removed.encoded.size
        removed.clear()
    }
}

internal func clientSessionKey(
    context: TlsClientContext,
    referenceIdentity: ReferenceIdentity,
    systemTrustLocation: ?LinuxSystemTrustLocation
): TlsSessionKey {
    TlsSessionKey(
        referenceIdentityKey(referenceIdentity),
        alpnContextKey(context.alpnProtocols()),
        trustContextKey(context.trust, systemTrustLocation),
        match (context.identity) {
            case Some(value) => value.contextIdentity
            case None => "none"
        },
        providerContextKey(context.providerManifest),
        securityContextKey(context.security)
    )
}

internal func serverSessionIdContext(
    context: TlsServerContext,
    systemTrustLocation: ?LinuxSystemTrustLocation
): Array<Byte> {
    let clientTrust = match (context.clientTrust) {
        case Some(value) => trustContextKey(value, systemTrustLocation)
        case None => "none"
    }
    let material = "provider=${providerContextKey(context.providerManifest)};" +
        "security=${securityContextKey(context.security)};" +
        "identity=${context.identity.contextIdentity};" +
        "alpn=${alpnContextKey(context.alpnProtocols())};" +
        "clientAuth=${clientAuthenticationKey(context.clientAuthentication)};" +
        "clientTrust=${clientTrust}"
    sessionDigest(material.toArray())
}

private func referenceIdentityKey(identity: ReferenceIdentity): String {
    match (identity) {
        case ReferenceIdentity.Dns(value) => "dns:${value.ascii}"
        case ReferenceIdentity.Ip(value) => ipIdentityKey(value)
    }
}

private func ipIdentityKey(value: IpAddress): String {
    let family = match (value.family) {
        case IpAddressFamily.Ipv4 => "4"
        case IpAddressFamily.Ipv6 => "6"
    }
    var encoded = "ip${family}:"
    for (octet in value.toOctets()) { encoded += "${octet}," }
    if (let Some(zone) <- value.zone) { encoded += "%${zone}" }
    encoded
}

private func alpnContextKey(protocols: Array<String>): String {
    var output = ""
    for (protocol in protocols) {
        output += "${protocol.size}:${protocol};"
    }
    output
}

private func trustContextKey(
    trust: TrustPolicy,
    systemTrustLocation: ?LinuxSystemTrustLocation
): String {
    let source = match (systemTrustLocation) {
        case Some(value) => value.sourceIdentity
        case None => "no-platform-source"
    }
    "${trust.contextIdentity}:${source}"
}

private func providerContextKey(manifest: TlsProviderManifest): String {
    "${manifest.providerId}:${manifest.fingerprint}"
}

private func securityContextKey(security: TlsSecurityPolicy): String {
    "${tlsVersionNumber(security.minimumVersion)}-${tlsVersionNumber(security.maximumVersion)}"
}

private func clientAuthenticationKey(value: ClientAuthentication): String {
    match (value) {
        case ClientAuthentication.None => "none"
        case ClientAuthentication.Optional => "optional"
        case ClientAuthentication.Required => "required"
    }
}

private func sessionDigest(input: Array<Byte>): Array<Byte> {
    let output = Array<Byte>(32, repeat: 0)
    let status = unsafe {
        let source = acquireArrayRawData(input)
        let destination = acquireArrayRawData(output)
        try {
            wirestack_tls_sha256(source.pointer, UInt64(input.size), destination.pointer)
        } finally {
            releaseArrayRawData(destination)
            releaseArrayRawData(source)
        }
    }
    if (status != 0) {
        throw TlsProviderException(
            TlsProviderErrorCode.InitializationFailed,
            "failed to derive TLS server session partition"
        )
    }
    output
}

private func clearSessionBytes(bytes: Array<Byte>): Unit {
    for (index in 0..bytes.size) { bytes[index] = 0 }
}
