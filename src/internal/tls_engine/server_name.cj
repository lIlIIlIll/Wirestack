package wirestack.internal.tls_engine

import wirestack.internal.common.*

public enum TlsServerNameSelectionErrorCode {
    | EmptyRoutes
    | TooManyRoutes
    | DuplicateServerName
    | MixedProviderIdentity
    | MissingServerName
    | InvalidServerName
    | NoMatchingServerName
}

public class TlsServerNameSelectionException <: Exception {
    public let code: TlsServerNameSelectionErrorCode
    public let serverName: ?String

    public init(
        code: TlsServerNameSelectionErrorCode,
        message: String,
        serverName!: ?String = None<String>
    ) {
        super(message)
        this.code = code
        this.serverName = serverName
    }

    protected override func getClassName(): String { "TlsServerNameSelectionException" }
}

/** One exact canonical SNI name mapped to one immutable server context. */
public struct TlsServerNameRoute {
    public let serverName: HostName
    public let context: TlsServerContext

    public init(serverName: HostName, context: TlsServerContext) {
        this.serverName = serverName
        this.context = context
    }
}

/**
 * Immutable exact-match SNI routing table. Once routing is enabled, absence or
 * non-match is rejected rather than falling back to an unrelated certificate.
 */
public class TlsServerContextSelector {
    private let entries: Array<TlsServerNameRoute>
    public let providerId: String
    public let providerFingerprint: String
    internal let providerManifest: TlsProviderManifest

    public init(routes: Array<TlsServerNameRoute>) {
        if (routes.isEmpty()) {
            throw TlsServerNameSelectionException(
                TlsServerNameSelectionErrorCode.EmptyRoutes,
                "TLS SNI selector requires at least one route"
            )
        }
        if (routes.size > 256) {
            throw TlsServerNameSelectionException(
                TlsServerNameSelectionErrorCode.TooManyRoutes,
                "TLS SNI selector supports at most 256 routes"
            )
        }
        let firstManifest = routes[0].context.providerManifest
        for (index in 0..routes.size) {
            let route = routes[index]
            if (!route.context.providerManifest.sameProviderInstance(firstManifest)) {
                throw TlsServerNameSelectionException(
                    TlsServerNameSelectionErrorCode.MixedProviderIdentity,
                    "all TLS SNI routes must use the same provider identity"
                )
            }
            for (prior in 0..index) {
                if (routes[prior].serverName == route.serverName) {
                    throw TlsServerNameSelectionException(
                        TlsServerNameSelectionErrorCode.DuplicateServerName,
                        "TLS SNI route names must not repeat",
                        serverName: Some(route.serverName.ascii)
                    )
                }
            }
        }
        entries = routes.clone()
        providerManifest = firstManifest
        providerId = firstManifest.providerId
        providerFingerprint = firstManifest.fingerprint
    }

    public func routes(): Array<TlsServerNameRoute> { entries.clone() }

    internal func select(encodedServerName: ?String): TlsServerContext {
        let raw = match (encodedServerName) {
            case Some(value) => value
            case None => throw TlsServerNameSelectionException(
                TlsServerNameSelectionErrorCode.MissingServerName,
                "TLS client did not provide SNI"
            )
        }
        let canonical = try {
            HostName(raw)
        } catch (_: IllegalArgumentException) {
            throw TlsServerNameSelectionException(
                TlsServerNameSelectionErrorCode.InvalidServerName,
                "TLS client provided invalid SNI",
                serverName: Some(raw)
            )
        }
        for (route in entries) {
            if (route.serverName == canonical) {
                return route.context
            }
        }
        throw TlsServerNameSelectionException(
            TlsServerNameSelectionErrorCode.NoMatchingServerName,
            "TLS SNI has no configured server context",
            serverName: Some(canonical.ascii)
        )
    }

    internal func initialSecurityPolicy(): TlsSecurityPolicy {
        var minimum = TlsVersion.Tls13
        var maximum = TlsVersion.Tls12
        for (route in entries) {
            match (route.context.security.minimumVersion) {
                case TlsVersion.Tls12 => minimum = TlsVersion.Tls12
                case _ => ()
            }
            match (route.context.security.maximumVersion) {
                case TlsVersion.Tls13 => maximum = TlsVersion.Tls13
                case _ => ()
            }
        }
        TlsSecurityPolicy(TlsSecurityProfile.Compatible, minimum, maximum)
    }
}
