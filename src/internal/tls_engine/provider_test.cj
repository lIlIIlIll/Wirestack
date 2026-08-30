package wirestack.internal.tls_engine

import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*
import wirestack.internal.common.*
import wirestack.internal.transport.*
import wirestack.internal.trust.*

@Test
class TlsProviderSubstitutionTest {
    @TestCase
    func testProviderUsesTheProductionFactoryContract(): Unit {
        let provider = TestTlsProviderFactory("test-one").create()
        try {
            @Expect(provider.manifest().providerId, "wirestack-test")
            @Expect(provider.manifest().fingerprint, "test-one")
            @Expect(provider.capabilities().supports(TlsCapability.Tls13))
            let context = TlsClientContext.builder(
                provider.manifest(),
                provider.capabilities()
            ).trust(TrustPolicy.customRoots(CertificateChain([
                DerCertificate(tlsTestCertificateDer())
            ])))
                .build()
            let engine = provider.createClientEngine(
                context,
                ReferenceIdentity.Dns(HostName("example.com")),
                serverName: None<HostName>
            )
            @Expect(isComplete(engine.handshakeStep()))
            engine.close()
        } finally {
            provider.close()
        }
    }

    @TestCase
    func objectsFromDifferentProviderInstancesCannotMix(): Unit {
        let first = TestTlsProvider("first")
        let second = TestTlsProvider("second")
        try {
            let context = TlsClientContext.builder(
                first.manifest(),
                first.capabilities()
            ).trust(TrustPolicy.customRoots(CertificateChain([
                DerCertificate(tlsTestCertificateDer())
            ])))
                .build()
            @ExpectThrows[TlsProviderException](
                second.createClientEngine(
                    context,
                    ReferenceIdentity.Dns(HostName("example.com")),
                    serverName: None<HostName>
                )
            )
        } finally {
            first.close()
            second.close()
        }
    }

    @TestCase
    func activeEngineRetainsProviderUntilItCloses(): Unit {
        let provider = TestTlsProvider("lifetime")
        let engine = provider.createEngine(
            TlsEngineRole.Client,
            TlsSecurityPolicy.forProfile(TlsSecurityProfile.Modern)
        )
        provider.close()
        @Expect(provider.closeRequested())
        @Expect(!provider.resourcesReleased())
        @Expect(isComplete(engine.handshakeStep()))
        engine.close()
        @Expect(provider.resourcesReleased())
        engine.close()
        @Expect(provider.resourcesReleased())
    }
}

private func isComplete(value: TlsEngineStep): Bool {
    match (value) {
        case TlsEngineStep.Complete => true
        case _ => false
    }
}

private class TestProviderLifetime {
    let mutex = Mutex()
    var active: Int64 = 0
    var closeWasRequested = false
    var released = false
}

/** Test-only provider. It is excluded from every release payload. */
public class TestTlsProvider <: TlsProvider {
    private let lifetime = TestProviderLifetime()
    private let providerManifest: TlsProviderManifest

    public init(identity: String) {
        providerManifest = TlsProviderManifest(
            "wirestack-test",
            "0",
            identity,
            "deterministic-test",
            "none",
            0x1ffu64,
            bindingIdentity: "test-${identity}"
        )
    }

    public func manifest(): TlsProviderManifest { providerManifest }
    public func capabilities(): TlsCapabilities {
        TlsCapabilities.fromProvider(providerManifest)
    }
    public func runtimeSnapshot(): TlsRuntimeSnapshot {
        TlsRuntimeSnapshot(
            providerManifest,
            "test-only",
            providerManifest.fingerprint,
            false,
            "test-only",
            ["1.2", "1.3"],
            ["1.1", "2"],
            ["test-only"]
        )
    }
    public func fillSecureRandom(output: Array<Byte>): Unit {
        for (index in 0..output.size) { output[index] = UInt8(UInt64(index % 251)) }
    }
    public func createEngine(_: TlsEngineRole, _: TlsSecurityPolicy): TlsEngine {
        synchronized(lifetime.mutex) {
            ensureOpen()
            lifetime.active++
            TestTlsEngine(providerManifest, lifetime)
        }
    }
    public func createClientEngine(
        context: TlsClientContext,
        _: ReferenceIdentity,
        serverName!: ?HostName
    ): TlsEngine {
        ensureMatching(context.providerManifest)
        createEngine(TlsEngineRole.Client, context.security)
    }
    public func createServerEngine(context: TlsServerContext): TlsEngine {
        ensureMatching(context.providerManifest)
        createEngine(TlsEngineRole.Server, context.security)
    }
    public func createServerEngine(selector: TlsServerContextSelector): TlsEngine {
        ensureMatching(selector.providerManifest)
        createEngine(
            TlsEngineRole.Server,
            TlsSecurityPolicy.forProfile(TlsSecurityProfile.Modern)
        )
    }
    public func close(): Unit {
        synchronized(lifetime.mutex) {
            lifetime.closeWasRequested = true
            if (lifetime.active == 0) { lifetime.released = true }
        }
    }
    public func closeRequested(): Bool {
        synchronized(lifetime.mutex) { lifetime.closeWasRequested }
    }
    public func resourcesReleased(): Bool {
        synchronized(lifetime.mutex) { lifetime.released }
    }
    private func ensureOpen(): Unit {
        if (lifetime.closeWasRequested) {
            throw TlsProviderException(TlsProviderErrorCode.Closed, "test provider is closed")
        }
    }
    private func ensureMatching(other: TlsProviderManifest): Unit {
        if (!providerManifest.sameProviderInstance(other)) {
            throw TlsProviderException(
                TlsProviderErrorCode.ProviderMismatch,
                "test provider instance mismatch"
            )
        }
    }
}

public class TestTlsProviderFactory <: TlsProviderFactory {
    private let identity: String
    public init(identity: String) { this.identity = identity }
    public func create(): TlsProvider { TestTlsProvider(identity) }
}

private class TestTlsEngine <: TlsEngine & HandshakeInfoTlsEngine {
    private let providerManifest: TlsProviderManifest
    private let lifetime: TestProviderLifetime
    private var closed = false

    init(providerManifest: TlsProviderManifest, lifetime: TestProviderLifetime) {
        this.providerManifest = providerManifest
        this.lifetime = lifetime
    }
    public func handshakeStep(): TlsEngineStep { TlsEngineStep.Complete }
    public func pendingCiphertext(): Int64 { 0 }
    public func drainCiphertext(_: MutableByteSpan): Int64 { 0 }
    public func feedCiphertext(source: ByteSpan): Int64 { source.length }
    public func readPlaintext(_: MutableByteSpan): TlsEngineReadResult {
        TlsEngineReadResult.PeerClosed
    }
    public func writePlaintext(source: ByteSpan): TlsEngineWriteResult {
        TlsEngineWriteResult.Consumed(source.length)
    }
    public func shutdownStep(): TlsEngineShutdownResult { TlsEngineShutdownResult.Complete }
    public func handshakeInfo(): TlsHandshakeInfo {
        TlsHandshakeInfo(
            TlsVersion.Tls13,
            "TLS_TEST_WITH_DETERMINISM",
            Some("h2"),
            None<CertificateChain>,
            None<TrustVerificationEvidence>,
            false,
            providerManifest
        )
    }
    public func close(): Unit {
        synchronized(lifetime.mutex) {
            if (closed) { return }
            closed = true
            lifetime.active--
            if (lifetime.closeWasRequested && lifetime.active == 0) {
                lifetime.released = true
            }
        }
    }
    public func isClosed(): Bool { closed }
}
