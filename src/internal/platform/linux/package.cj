package wirestack.internal.platform.linux

import std.fs.*

private let LINUX_CA_BUNDLES: Array<String> = [
    "/etc/ssl/certs/ca-certificates.crt",
    "/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem",
    "/etc/pki/tls/certs/ca-bundle.crt",
    "/etc/ssl/ca-bundle.pem"
]

private let LINUX_CA_DIRECTORIES: Array<String> = [
    "/etc/ssl/certs",
    "/etc/pki/tls/certs"
]

public enum LinuxSystemTrustErrorCode {
    | NoUsableTrustSource
    | InvalidCandidate
}

public class LinuxSystemTrustException <: Exception {
    public let code: LinuxSystemTrustErrorCode

    public init(code: LinuxSystemTrustErrorCode, message: String) {
        super(message)
        this.code = code
    }

    protected override func getClassName(): String { "LinuxSystemTrustException" }
}

/** Explicit CA source selected without provider defaults or environment fallback. */
public struct LinuxSystemTrustLocation {
    public let certificateBundle: ?String
    public let hashedCertificateDirectory: ?String
    public let sourceIdentity: String

    internal init(bundle: ?String, directory: ?String, sourceIdentity: String) {
        this.certificateBundle = bundle
        hashedCertificateDirectory = directory
        this.sourceIdentity = sourceIdentity
    }
}

public class LinuxSystemTrustAdapter {
    public static func bundleCandidates(): Array<String> { LINUX_CA_BUNDLES.clone() }
    public static func directoryCandidates(): Array<String> { LINUX_CA_DIRECTORIES.clone() }

    /**
     * Selects the first readable non-empty regular bundle. Only when none exists,
     * selects the first readable directory. It never calls provider defaults.
     */
    public static func discover(): LinuxSystemTrustLocation {
        discoverFrom(LINUX_CA_BUNDLES, LINUX_CA_DIRECTORIES)
    }

    public static func discoverFrom(
        bundleCandidates: Array<String>,
        directoryCandidates: Array<String>
    ): LinuxSystemTrustLocation {
        for (candidate in bundleCandidates) {
            match (usableBundle(candidate)) {
                case Some(size) => return LinuxSystemTrustLocation(
                    Some(candidate),
                    None<String>,
                    "linux-ca-bundle:${candidate}:${size}"
                )
                case None => ()
            }
        }
        for (candidate in directoryCandidates) {
            if (usableDirectory(candidate)) {
                return LinuxSystemTrustLocation(
                    None<String>,
                    Some(candidate),
                    "linux-ca-directory:${candidate}"
                )
            }
        }
        throw LinuxSystemTrustException(
            LinuxSystemTrustErrorCode.NoUsableTrustSource,
            "no usable Linux CA bundle or hashed certificate directory was found"
        )
    }
}

private func usableBundle(path: String): ?Int64 {
    if (path.isEmpty() || path.contains("\0") || !Path(path).isAbsolute() || !exists(path)) {
        return None<Int64>
    }
    try {
        let info = FileInfo(path)
        if (info.isRegular() && info.canRead() && info.size > 0) {
            Some(info.size)
        } else {
            None<Int64>
        }
    } catch (_: Exception) {
        None<Int64>
    }
}

private func usableDirectory(path: String): Bool {
    if (path.isEmpty() || path.contains("\0") || !Path(path).isAbsolute() || !exists(path)) {
        return false
    }
    try {
        let info = FileInfo(path)
        info.isDirectory() && info.canRead()
    } catch (_: Exception) {
        false
    }
}
