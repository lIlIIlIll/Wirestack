package wirestack.internal.platform.linux

import std.collection.ArrayList
import std.fs.*

private let TRUST_NATIVE_OK: Int32 = 0
private let MAXIMUM_CA_SOURCE_BYTES: Int64 = 32 * 1024 * 1024
private let MAXIMUM_HASHED_CA_ENTRIES: Int64 = 4096

foreign func wirestack_tls_sha256(
    input: CPointer<UInt8>,
    size: UInt64,
    output: CPointer<UInt8>
): Int32

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
                case Some(_) => return LinuxSystemTrustLocation(
                    Some(candidate),
                    None<String>,
                    "linux-ca-bundle:${candidate}:${trustContentDigest(File.readFrom(candidate))}"
                )
                case None => ()
            }
        }
        for (candidate in directoryCandidates) {
            if (let Some(identity) <- directoryContentIdentity(candidate)) {
                return LinuxSystemTrustLocation(
                    None<String>,
                    Some(candidate),
                    "linux-ca-directory:${candidate}:${identity}"
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
        if (info.isRegular() && info.canRead() && info.size > 0 &&
            info.size <= MAXIMUM_CA_SOURCE_BYTES) {
            Some(info.size)
        } else {
            None<Int64>
        }
    } catch (_: Exception) {
        None<Int64>
    }
}

private func directoryContentIdentity(path: String): ?String {
    if (path.isEmpty() || path.contains("\0") || !Path(path).isAbsolute() || !exists(path)) {
        return None<String>
    }
    try {
        let info = FileInfo(path)
        if (!info.isDirectory() || !info.canRead()) {
            return None<String>
        }
        let paths = ArrayList<String>()
        Directory.walk(Path(path)) { entry =>
            if (isUsableHashedCertificate(entry)) {
                paths.add(entry.path.toString())
            }
            paths.size <= MAXIMUM_HASHED_CA_ENTRIES
        }
        if (paths.isEmpty() || paths.size > MAXIMUM_HASHED_CA_ENTRIES) {
            return None<String>
        }
        let ordered = paths.toArray()
        sortTrustPaths(ordered)
        let material = ArrayList<Byte>()
        var total: Int64 = 0
        for (entryPath in ordered) {
            let bytes = File.readFrom(entryPath)
            total += bytes.size
            if (total > MAXIMUM_CA_SOURCE_BYTES) { return None<String> }
            appendTrustField(material, entryPath.toArray())
            appendTrustField(material, bytes)
        }
        Some(trustContentDigest(material.toArray()))
    } catch (_: Exception) {
        None<String>
    }
}

private func sortTrustPaths(paths: Array<String>): Unit {
    for (index in 1..paths.size) {
        let current = paths[index]
        var insertion = index
        while (insertion > 0 && trustPathLess(current, paths[insertion - 1])) {
            paths[insertion] = paths[insertion - 1]
            insertion -= 1
        }
        paths[insertion] = current
    }
}

private func trustPathLess(left: String, right: String): Bool {
    let leftBytes = left.toArray()
    let rightBytes = right.toArray()
    let common = min(leftBytes.size, rightBytes.size)
    for (index in 0..common) {
        if (leftBytes[index] < rightBytes[index]) { return true }
        if (leftBytes[index] > rightBytes[index]) { return false }
    }
    leftBytes.size < rightBytes.size
}

private func appendTrustField(output: ArrayList<Byte>, value: Array<Byte>): Unit {
    let size = UInt64(value.size)
    for (shift in [56u64, 48u64, 40u64, 32u64, 24u64, 16u64, 8u64, 0u64]) {
        output.add(UInt8((size >> shift) & 0xffu64))
    }
    output.add(all: value)
}

private func trustContentDigest(inputBytes: Array<Byte>): String {
    let digest = Array<Byte>(32, repeat: 0u8)
    let status = unsafe {
        let input = acquireArrayRawData(inputBytes)
        let output = acquireArrayRawData(digest)
        try { wirestack_tls_sha256(input.pointer, UInt64(inputBytes.size), output.pointer) }
        finally { releaseArrayRawData(output); releaseArrayRawData(input) }
    }
    if (status != TRUST_NATIVE_OK) {
        throw LinuxSystemTrustException(
            LinuxSystemTrustErrorCode.InvalidCandidate,
            "failed to derive Linux trust-source identity"
        )
    }
    let alphabet = "0123456789abcdef".toArray()
    let encoded = Array<Byte>(64, repeat: 0u8)
    for ((index, value) in digest.enumerate()) {
        encoded[index * 2] = alphabet[Int64(value >> 4)]
        encoded[index * 2 + 1] = alphabet[Int64(value & 0x0f)]
    }
    String.fromUtf8(encoded)
}

private func isUsableHashedCertificate(entry: FileInfo): Bool {
    if (!isHashedCertificateName(entry.name)) {
        return false
    }
    try {
        (entry.isRegular() || entry.isSymbolicLink()) && entry.canRead() && entry.size > 0
    } catch (_: Exception) {
        false
    }
}

private func isHashedCertificateName(name: String): Bool {
    let bytes = name.toArray()
    if (bytes.size < 10 || bytes[8] != b'.') {
        return false
    }
    for (index in 0..8) {
        if (!bytes[index].isAsciiHex()) {
            return false
        }
    }
    for (index in 9..bytes.size) {
        if (!bytes[index].isAsciiNumber()) {
            return false
        }
    }
    true
}
