package wirestack.internal.tls_engine

import std.sync.*
import wirestack.internal.common.*
import wirestack.internal.platform.linux.*
import wirestack.internal.transport.*
import wirestack.internal.trust.*

private let ENGINE_CLIENT: Int32 = 0
private let ENGINE_SERVER: Int32 = 1
private let ENGINE_COMPLETE: Int32 = 0
private let ENGINE_WANT_READ: Int32 = 1
private let ENGINE_WANT_WRITE: Int32 = 2
private let ENGINE_IO_COMPLETE: Int32 = 0
private let ENGINE_IO_WANT_READ: Int32 = 1
private let ENGINE_IO_WANT_WRITE: Int32 = 2
private let ENGINE_IO_CLOSED: Int32 = 3
private let NATIVE_OK: Int32 = 0
private let MAX_SIGNED_INT64: UInt64 = 0x7fffffffffffffffu64

foreign func wirestack_tls_engine_create(
    providerHandle: UInt64,
    role: Int32,
    minimumTlsVersion: Int32,
    maximumTlsVersion: Int32,
    outEngineHandle: CPointer<UInt64>
): Int32
foreign func wirestack_tls_engine_destroy(engineHandle: UInt64): Unit
foreign func wirestack_tls_engine_add_trust_anchor_der(
    engineHandle: UInt64,
    input: CPointer<UInt8>,
    size: UInt64
): Int32
foreign func wirestack_tls_engine_add_spki_sha256_pin(
    engineHandle: UInt64,
    digest: CPointer<UInt8>,
    scope: Int32
): Int32
foreign func wirestack_tls_engine_load_verify_bundle(
    engineHandle: UInt64,
    certificateBundle: CString
): Int32
foreign func wirestack_tls_engine_load_verify_directory(
    engineHandle: UInt64,
    hashedCertificateDirectory: CString
): Int32
foreign func wirestack_tls_engine_set_server_name(
    engineHandle: UInt64,
    serverName: CString
): Int32
foreign func wirestack_tls_engine_set_dns_reference_identity(
    engineHandle: UInt64,
    dnsName: CString
): Int32
foreign func wirestack_tls_engine_set_ip_reference_identity(
    engineHandle: UInt64,
    address: CPointer<UInt8>,
    size: UInt64
): Int32
foreign func wirestack_tls_engine_enable_peer_verification(engineHandle: UInt64): Int32
foreign func wirestack_tls_engine_handshake_step(
    engineHandle: UInt64,
    outStep: CPointer<Int32>
): Int32
foreign func wirestack_tls_engine_pending_ciphertext(
    engineHandle: UInt64,
    outSize: CPointer<UInt64>
): Int32
foreign func wirestack_tls_engine_drain_ciphertext(
    engineHandle: UInt64,
    output: CPointer<UInt8>,
    size: UInt64,
    outRead: CPointer<UInt64>
): Int32
foreign func wirestack_tls_engine_feed_ciphertext(
    engineHandle: UInt64,
    input: CPointer<UInt8>,
    size: UInt64,
    outWritten: CPointer<UInt64>
): Int32
foreign func wirestack_tls_engine_read_plaintext(
    engineHandle: UInt64,
    output: CPointer<UInt8>,
    size: UInt64,
    outRead: CPointer<UInt64>,
    outStep: CPointer<Int32>
): Int32
foreign func wirestack_tls_engine_write_plaintext(
    engineHandle: UInt64,
    input: CPointer<UInt8>,
    size: UInt64,
    outWritten: CPointer<UInt64>,
    outStep: CPointer<Int32>
): Int32

public enum TlsEngineRole {
    | Client
    | Server
}

public enum TlsEngineStep {
    | Complete
    | WantRead
    | WantWrite
}

public enum TlsEngineReadResult {
    | Data(Int64)
    | WantRead
    | WantWrite
    | PeerClosed
}

public enum TlsEngineWriteResult {
    | Consumed(Int64)
    | WantRead
    | WantWrite
    | PeerClosed
}

/** Provider-neutral external-I/O TLS state machine. */
public interface TlsEngine <: Resource {
    func handshakeStep(): TlsEngineStep
    func pendingCiphertext(): Int64
    func drainCiphertext(destination: MutableByteSpan): Int64
    func feedCiphertext(source: ByteSpan): Int64
    func readPlaintext(destination: MutableByteSpan): TlsEngineReadResult
    func writePlaintext(source: ByteSpan): TlsEngineWriteResult
    func close(): Unit
}

public enum TlsEngineErrorCode {
    | ProviderFailure
    | Closed
    | NoProgress
    | UnexpectedTransportEof
}

/** Stable TLS-pump failure without provider-native types or secret material. */
public class TlsEngineException <: NetworkException {
    public let tlsCode: TlsEngineErrorCode

    public init(code: TlsEngineErrorCode, message: String) {
        super(
            NetworkErrorCategory.System,
            NetworkPhase.TlsHandshake,
            match (code) {
                case TlsEngineErrorCode.Closed => NetworkErrorCode.Closed
                case TlsEngineErrorCode.UnexpectedTransportEof => NetworkErrorCode.UnexpectedEof
                case _ => NetworkErrorCode.SystemFailure
            },
            message,
            retryability: Retryability.Never
        )
        tlsCode = code
    }

    protected override func getClassName(): String { "TlsEngineException" }
}

private func nativeRole(role: TlsEngineRole): Int32 {
    match (role) {
        case TlsEngineRole.Client => ENGINE_CLIENT
        case TlsEngineRole.Server => ENGINE_SERVER
    }
}

private func providerFailure(operation: String, status: Int32): TlsEngineException {
    TlsEngineException(
        TlsEngineErrorCode.ProviderFailure,
        "TLS provider ${operation} failed: ${status}"
    )
}

/** AWS-LC memory-BIO engine. It never owns or accesses a socket. */
public class AwsLcTlsEngine <: TlsEngine {
    private let mutex = Mutex()
    private var handle: UInt64

    internal init(
        providerHandle: UInt64,
        role: TlsEngineRole,
        security: TlsSecurityPolicy
    ) {
        let output = Array<UInt64>(1, repeat: 0u64)
        let status = unsafe {
            let raw = acquireArrayRawData(output)
            try {
                wirestack_tls_engine_create(
                    providerHandle,
                    nativeRole(role),
                    Int32(tlsVersionNumber(security.minimumVersion)),
                    Int32(tlsVersionNumber(security.maximumVersion)),
                    raw.pointer
                )
            } finally {
                releaseArrayRawData(raw)
            }
        }
        if (status != NATIVE_OK || output[0] == 0u64) {
            throw providerFailure("engine creation", status)
        }
        handle = output[0]
    }

    internal func configureClientAuthentication(
        trust: TrustPolicy,
        referenceIdentity: ReferenceIdentity,
        serverName: ?HostName,
        systemTrustLocation: ?LinuxSystemTrustLocation
    ): Unit {
        synchronized(mutex) {
            let current = requireOpen()
            configureTrust(current, trust, systemTrustLocation)
            if (let Some(name) <- serverName) {
                withCString(name.ascii, {value =>
                    requireConfigurationSuccess(
                        "SNI server name",
                        unsafe { wirestack_tls_engine_set_server_name(current, value) }
                    )
                })
            }
            match (referenceIdentity) {
                case ReferenceIdentity.Dns(host) =>
                    withCString(host.ascii, {value =>
                        requireConfigurationSuccess(
                            "DNS reference identity",
                            unsafe {
                                wirestack_tls_engine_set_dns_reference_identity(current, value)
                            }
                        )
                    })
                case ReferenceIdentity.Ip(address) =>
                    if (address.zone.isSome()) {
                        throw TlsEngineException(
                            TlsEngineErrorCode.ProviderFailure,
                            "TLS IP reference identity cannot contain a zone"
                        )
                    }
                    let octets = address.toOctets()
                    let status = unsafe {
                        let input = acquireArrayRawData(octets)
                        try {
                            wirestack_tls_engine_set_ip_reference_identity(
                                current,
                                input.pointer,
                                UInt64(octets.size)
                            )
                        } finally {
                            releaseArrayRawData(input)
                        }
                    }
                    requireConfigurationSuccess("IP reference identity", status)
            }
            requireConfigurationSuccess(
                "peer verification",
                unsafe { wirestack_tls_engine_enable_peer_verification(current) }
            )
        }
    }

    public func handshakeStep(): TlsEngineStep {
        synchronized(mutex) {
            let current = requireOpen()
            let output = Array<Int32>(1, repeat: -1)
            let status = unsafe {
                let raw = acquireArrayRawData(output)
                try {
                    wirestack_tls_engine_handshake_step(current, raw.pointer)
                } finally {
                    releaseArrayRawData(raw)
                }
            }
            if (status != NATIVE_OK) {
                throw providerFailure("handshake step", status)
            }
            let value = output[0]
            if (value == ENGINE_COMPLETE) {
                TlsEngineStep.Complete
            } else if (value == ENGINE_WANT_READ) {
                TlsEngineStep.WantRead
            } else if (value == ENGINE_WANT_WRITE) {
                TlsEngineStep.WantWrite
            } else {
                throw providerFailure("handshake step result", value)
            }
        }
    }

    public func pendingCiphertext(): Int64 {
        synchronized(mutex) {
            let current = requireOpen()
            let output = Array<UInt64>(1, repeat: 0u64)
            let status = unsafe {
                let raw = acquireArrayRawData(output)
                try {
                    wirestack_tls_engine_pending_ciphertext(current, raw.pointer)
                } finally {
                    releaseArrayRawData(raw)
                }
            }
            if (status != NATIVE_OK || output[0] > MAX_SIGNED_INT64) {
                throw providerFailure("pending ciphertext query", status)
            }
            Int64(output[0])
        }
    }

    public func drainCiphertext(destination: MutableByteSpan): Int64 {
        if (destination.isEmpty()) {
            return 0
        }
        synchronized(mutex) {
            let current = requireOpen()
            let output = Array<UInt64>(1, repeat: 0u64)
            let status = unsafe {
                let bytes = acquireArrayRawData(destination.bytes)
                let count = acquireArrayRawData(output)
                try {
                    wirestack_tls_engine_drain_ciphertext(
                        current,
                        bytes.pointer + destination.offset,
                        UInt64(destination.length),
                        count.pointer
                    )
                } finally {
                    releaseArrayRawData(count)
                    releaseArrayRawData(bytes)
                }
            }
            if (status != NATIVE_OK || output[0] > UInt64(destination.length)) {
                throw providerFailure("ciphertext drain", status)
            }
            Int64(output[0])
        }
    }

    public func feedCiphertext(source: ByteSpan): Int64 {
        if (source.isEmpty()) {
            return 0
        }
        synchronized(mutex) {
            let current = requireOpen()
            let output = Array<UInt64>(1, repeat: 0u64)
            let status = unsafe {
                let bytes = acquireArrayRawData(source.bytes)
                let count = acquireArrayRawData(output)
                try {
                    wirestack_tls_engine_feed_ciphertext(
                        current,
                        bytes.pointer + source.offset,
                        UInt64(source.length),
                        count.pointer
                    )
                } finally {
                    releaseArrayRawData(count)
                    releaseArrayRawData(bytes)
                }
            }
            if (status != NATIVE_OK || output[0] > UInt64(source.length)) {
                throw providerFailure("ciphertext feed", status)
            }
            Int64(output[0])
        }
    }

    public func readPlaintext(destination: MutableByteSpan): TlsEngineReadResult {
        if (destination.isEmpty()) {
            return TlsEngineReadResult.Data(0)
        }
        synchronized(mutex) {
            let current = requireOpen()
            let countOutput = Array<UInt64>(1, repeat: 0u64)
            let stepOutput = Array<Int32>(1, repeat: -1)
            let status = unsafe {
                let bytes = acquireArrayRawData(destination.bytes)
                let count = acquireArrayRawData(countOutput)
                let step = acquireArrayRawData(stepOutput)
                try {
                    wirestack_tls_engine_read_plaintext(
                        current,
                        bytes.pointer + destination.offset,
                        UInt64(destination.length),
                        count.pointer,
                        step.pointer
                    )
                } finally {
                    releaseArrayRawData(step)
                    releaseArrayRawData(count)
                    releaseArrayRawData(bytes)
                }
            }
            if (status != NATIVE_OK || countOutput[0] > UInt64(destination.length)) {
                throw providerFailure("plaintext read", status)
            }
            decodeReadResult(stepOutput[0], Int64(countOutput[0]))
        }
    }

    public func writePlaintext(source: ByteSpan): TlsEngineWriteResult {
        if (source.isEmpty()) {
            return TlsEngineWriteResult.Consumed(0)
        }
        synchronized(mutex) {
            let current = requireOpen()
            let countOutput = Array<UInt64>(1, repeat: 0u64)
            let stepOutput = Array<Int32>(1, repeat: -1)
            let status = unsafe {
                let bytes = acquireArrayRawData(source.bytes)
                let count = acquireArrayRawData(countOutput)
                let step = acquireArrayRawData(stepOutput)
                try {
                    wirestack_tls_engine_write_plaintext(
                        current,
                        bytes.pointer + source.offset,
                        UInt64(source.length),
                        count.pointer,
                        step.pointer
                    )
                } finally {
                    releaseArrayRawData(step)
                    releaseArrayRawData(count)
                    releaseArrayRawData(bytes)
                }
            }
            if (status != NATIVE_OK || countOutput[0] > UInt64(source.length)) {
                throw providerFailure("plaintext write", status)
            }
            decodeWriteResult(stepOutput[0], Int64(countOutput[0]))
        }
    }

    public func close(): Unit {
        synchronized(mutex) {
            let current = handle
            if (current != 0u64) {
                handle = 0u64
                unsafe { wirestack_tls_engine_destroy(current) }
            }
        }
    }

    public func isClosed(): Bool {
        synchronized(mutex) { handle == 0u64 }
    }

    private func requireOpen(): UInt64 {
        if (handle == 0u64) {
            throw TlsEngineException(TlsEngineErrorCode.Closed, "TLS engine is closed")
        }
        handle
    }

    ~init() {
        let current = handle
        if (current != 0u64) {
            handle = 0u64
            unsafe { wirestack_tls_engine_destroy(current) }
        }
    }
}

private func configureTrust(
    engineHandle: UInt64,
    trust: TrustPolicy,
    systemTrustLocation: ?LinuxSystemTrustLocation
): Unit {
    match (trust.kind) {
        case TrustPolicyKind.System => loadSystemTrust(engineHandle, systemTrustLocation)
        case TrustPolicyKind.CustomRoots => addCustomRoots(engineHandle, trust)
        case TrustPolicyKind.SystemPlusCustomRoots =>
            loadSystemTrust(engineHandle, systemTrustLocation)
            addCustomRoots(engineHandle, trust)
        case TrustPolicyKind.PinnedPublicKeys => addPublicKeyPins(engineHandle, trust)
    }
}

private func addPublicKeyPins(engineHandle: UInt64, trust: TrustPolicy): Unit {
    for (pin in trust.pins()) {
        let digest = pin.digestBytes()
        let status = unsafe {
            let input = acquireArrayRawData(digest)
            try {
                wirestack_tls_engine_add_spki_sha256_pin(
                    engineHandle,
                    input.pointer,
                    nativePinScope(pin.scope)
                )
            } finally {
                releaseArrayRawData(input)
            }
        }
        requireConfigurationSuccess("SPKI SHA-256 pin", status)
    }
}

private func nativePinScope(value: PinScope): Int32 {
    match (value) {
        case PinScope.LeafSubjectPublicKeyInfo => 0
        case PinScope.AnyCertificateSubjectPublicKeyInfo => 1
    }
}

private func addCustomRoots(engineHandle: UInt64, trust: TrustPolicy): Unit {
    let roots = match (trust.customRootChain()) {
        case Some(value) => value
        case None => throw TlsEngineException(
            TlsEngineErrorCode.ProviderFailure,
            "custom-root trust policy contains no roots"
        )
    }
    for (certificate in roots.certificates()) {
        let der = certificate.derBytes()
        let status = unsafe {
            let input = acquireArrayRawData(der)
            try {
                wirestack_tls_engine_add_trust_anchor_der(
                    engineHandle,
                    input.pointer,
                    UInt64(der.size)
                )
            } finally {
                releaseArrayRawData(input)
            }
        }
        requireConfigurationSuccess("custom trust anchor", status)
    }
}

private func loadSystemTrust(
    engineHandle: UInt64,
    location: ?LinuxSystemTrustLocation
): Unit {
    let source = match (location) {
        case Some(value) => value
        case None => throw TlsEngineException(
            TlsEngineErrorCode.ProviderFailure,
            "Linux system trust requires an explicit discovered CA source"
        )
    }
    match (source.certificateBundle) {
        case Some(path) => withCString(path, {value =>
            requireConfigurationSuccess(
                "Linux CA bundle",
                unsafe { wirestack_tls_engine_load_verify_bundle(engineHandle, value) }
            )
        })
        case None => match (source.hashedCertificateDirectory) {
            case Some(path) => withCString(path, {value =>
                requireConfigurationSuccess(
                    "Linux hashed CA directory",
                    unsafe { wirestack_tls_engine_load_verify_directory(engineHandle, value) }
                )
            })
            case None => throw TlsEngineException(
                TlsEngineErrorCode.ProviderFailure,
                "Linux system trust location contains no source"
            )
        }
    }
}

private func withCString(value: String, action: (CString) -> Unit): Unit {
    unsafe {
        let encoded = LibC.mallocCString(value)
        try {
            action(encoded)
        } finally {
            LibC.free(encoded)
        }
    }
}

private func requireConfigurationSuccess(operation: String, status: Int32): Unit {
    if (status != NATIVE_OK) {
        throw providerFailure(operation, status)
    }
}

internal func createAwsLcTlsEngine(
    providerHandle: UInt64,
    role: TlsEngineRole,
    security: TlsSecurityPolicy
): TlsEngine {
    AwsLcTlsEngine(providerHandle, role, security)
}

private func decodeReadResult(step: Int32, count: Int64): TlsEngineReadResult {
    if (step == ENGINE_IO_COMPLETE) {
        if (count <= 0) {
            throw providerFailure("plaintext read result", step)
        }
        TlsEngineReadResult.Data(count)
    } else if (step == ENGINE_IO_WANT_READ) {
        TlsEngineReadResult.WantRead
    } else if (step == ENGINE_IO_WANT_WRITE) {
        TlsEngineReadResult.WantWrite
    } else if (step == ENGINE_IO_CLOSED) {
        TlsEngineReadResult.PeerClosed
    } else {
        throw providerFailure("plaintext read result", step)
    }
}

private func decodeWriteResult(step: Int32, count: Int64): TlsEngineWriteResult {
    if (step == ENGINE_IO_COMPLETE) {
        if (count <= 0) {
            throw providerFailure("plaintext write result", step)
        }
        TlsEngineWriteResult.Consumed(count)
    } else if (step == ENGINE_IO_WANT_READ) {
        TlsEngineWriteResult.WantRead
    } else if (step == ENGINE_IO_WANT_WRITE) {
        TlsEngineWriteResult.WantWrite
    } else if (step == ENGINE_IO_CLOSED) {
        TlsEngineWriteResult.PeerClosed
    } else {
        throw providerFailure("plaintext write result", step)
    }
}

/**
 * Bounded bridge between a provider memory-BIO engine and a DuplexTransport.
 * It preserves the caller's single absolute OperationContext across all loops.
 */
public class TlsEnginePump {
    private let ciphertextChunkSize: Int64
    private let transportReadMutex = Mutex()
    private let transportWriteMutex = Mutex()

    public init(ciphertextChunkSize!: Int64 = 16 * 1024) {
        if (ciphertextChunkSize <= 0 || ciphertextChunkSize > 64 * 1024) {
            throw IllegalArgumentException("TLS ciphertext chunk size must be in 1..65536")
        }
        this.ciphertextChunkSize = ciphertextChunkSize
    }

    public func driveHandshake(
        engine: TlsEngine,
        transport: DuplexTransport,
        context!: OperationContext = OperationContext.background()
    ): Unit {
        let input = Array<Byte>(ciphertextChunkSize, repeat: 0)
        let output = Array<Byte>(ciphertextChunkSize, repeat: 0)
        while (true) {
            checkContext(context)
            let step = engine.handshakeStep()
            let flushed = flushCiphertext(engine, transport, output, context)
            match (step) {
                case TlsEngineStep.Complete => return
                case TlsEngineStep.WantWrite =>
                    if (flushed == 0) {
                        throw TlsEngineException(
                            TlsEngineErrorCode.NoProgress,
                            "TLS engine requested write without producing ciphertext"
                        )
                    }
                case TlsEngineStep.WantRead =>
                    receiveCiphertext(engine, transport, input, context)
            }
        }
    }

    public func readPlaintext(
        engine: TlsEngine,
        transport: DuplexTransport,
        destination: MutableByteSpan,
        context!: OperationContext = OperationContext.background()
    ): ReadResult {
        if (destination.isEmpty()) {
            return ReadResult.Data(0)
        }
        let input = Array<Byte>(ciphertextChunkSize, repeat: 0)
        let output = Array<Byte>(ciphertextChunkSize, repeat: 0)
        while (true) {
            checkContext(context)
            let result = engine.readPlaintext(destination)
            let flushed = flushCiphertext(engine, transport, output, context)
            match (result) {
                case TlsEngineReadResult.Data(count) =>
                    if (count <= 0 || count > destination.length) {
                        throw noProgress("TLS engine returned invalid plaintext read progress")
                    }
                    return ReadResult.Data(count)
                case TlsEngineReadResult.PeerClosed => return ReadResult.EndOfStream
                case TlsEngineReadResult.WantRead =>
                    receiveCiphertext(engine, transport, input, context)
                case TlsEngineReadResult.WantWrite =>
                    if (flushed == 0) {
                        throw noProgress("TLS plaintext read requested write without ciphertext")
                }
            }
        }
        throw noProgress("TLS plaintext read loop terminated without a result")
    }

    public func writePlaintext(
        engine: TlsEngine,
        transport: DuplexTransport,
        source: ByteSpan,
        context!: OperationContext = OperationContext.background()
    ): Int64 {
        if (source.isEmpty()) {
            return 0
        }
        let input = Array<Byte>(ciphertextChunkSize, repeat: 0)
        let output = Array<Byte>(ciphertextChunkSize, repeat: 0)
        while (true) {
            checkContext(context)
            let result = engine.writePlaintext(source)
            let flushed = flushCiphertext(engine, transport, output, context)
            match (result) {
                case TlsEngineWriteResult.Consumed(count) =>
                    if (count <= 0 || count > source.length) {
                        throw noProgress("TLS engine returned invalid plaintext write progress")
                    }
                    return count
                case TlsEngineWriteResult.PeerClosed =>
                    throw TlsEngineException(
                        TlsEngineErrorCode.UnexpectedTransportEof,
                        "TLS peer closed before plaintext write completed"
                    )
                case TlsEngineWriteResult.WantRead =>
                    receiveCiphertext(engine, transport, input, context)
                case TlsEngineWriteResult.WantWrite =>
                    if (flushed == 0) {
                        throw noProgress("TLS plaintext write requested write without ciphertext")
                }
            }
        }
        throw noProgress("TLS plaintext write loop terminated without a result")
    }

    private func flushCiphertext(
        engine: TlsEngine,
        transport: DuplexTransport,
        buffer: Array<Byte>,
        context: OperationContext
    ): Int64 {
        synchronized(transportWriteMutex) {
            var total: Int64 = 0
            while (engine.pendingCiphertext() > 0) {
                checkContext(context)
                let requested = min(engine.pendingCiphertext(), buffer.size)
                let drained = engine.drainCiphertext(MutableByteSpan(buffer, length: requested))
                if (drained <= 0 || drained > requested) {
                    throw noProgress("TLS engine failed to drain pending ciphertext")
                }
                var remaining = ByteSpan(buffer, length: drained)
                while (!remaining.isEmpty()) {
                    checkContext(context)
                    let written = transport.writeSome(remaining, context: context)
                    if (written <= 0 || written > remaining.length) {
                        throw noProgress("transport failed to write TLS ciphertext")
                    }
                    remaining = remaining.advance(written)
                }
                total += drained
            }
            total
        }
    }

    private func receiveCiphertext(
        engine: TlsEngine,
        transport: DuplexTransport,
        buffer: Array<Byte>,
        context: OperationContext
    ): Unit {
        synchronized(transportReadMutex) {
            checkContext(context)
            match (transport.readSome(MutableByteSpan(buffer), context: context)) {
                case ReadResult.EndOfStream =>
                    throw TlsEngineException(
                        TlsEngineErrorCode.UnexpectedTransportEof,
                        "transport reached EOF while TLS expected a record"
                    )
                case ReadResult.Data(count) =>
                    if (count <= 0 || count > buffer.size) {
                        throw noProgress("transport returned no TLS record progress")
                    }
                    feedAll(engine, ByteSpan(buffer, length: count))
            }
        }
    }

    private func feedAll(engine: TlsEngine, source: ByteSpan): Unit {
        var remaining = source
        while (!remaining.isEmpty()) {
            let accepted = engine.feedCiphertext(remaining)
            if (accepted <= 0 || accepted > remaining.length) {
                throw TlsEngineException(
                    TlsEngineErrorCode.NoProgress,
                    "TLS engine failed to accept transport ciphertext"
                )
            }
            remaining = remaining.advance(accepted)
        }
    }

    private func checkContext(context: OperationContext): Unit {
        if (context.isCancellationRequested()) {
            throw NetworkException(
                NetworkErrorCategory.Cancelled,
                NetworkPhase.TlsHandshake,
                NetworkErrorCode.Cancelled,
                "TLS handshake was cancelled",
                retryability: Retryability.Never
            )
        }
        if (context.isDeadlineExceeded()) {
            throw NetworkException(
                NetworkErrorCategory.DeadlineExceeded,
                NetworkPhase.TlsHandshake,
                NetworkErrorCode.TimedOut,
                "TLS handshake deadline exceeded",
                retryability: Retryability.Never
            )
        }
    }

    private func noProgress(message: String): TlsEngineException {
        TlsEngineException(TlsEngineErrorCode.NoProgress, message)
    }
}
