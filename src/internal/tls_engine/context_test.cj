package wirestack.internal.tls_engine

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import wirestack.internal.trust.*

@Test
class TlsContextTest {
    @TestCase
    func linuxCapabilitiesAreExplicitAndNeverInferredFromProviderNames(): Unit {
        let capabilities = TlsCapabilities.fromProvider(fullManifest())

        @Expect(!capabilities.supports(TlsCapability.SystemTrust))
        @Expect(capabilities.supports(TlsCapability.CustomRoots))
        @Expect(!capabilities.supports(TlsCapability.HardwareKeys))
        @Expect(capabilities.supports(TlsCapability.ClientCertificate))
        @Expect(capabilities.supports(TlsCapability.ServerMode))
        @Expect(capabilities.supports(TlsCapability.Tls12))
        @Expect(capabilities.supports(TlsCapability.Tls13))
        @Expect(capabilities.supports(TlsCapability.Http2))
        @Expect(!capabilities.supports(TlsCapability.NetworkBinding))

        let withAdapters = TlsCapabilities.fromProvider(
            fullManifest(),
            systemTrustAvailable: true,
            hardwareKeysAvailable: true,
            networkBindingAvailable: true
        )
        @Expect(withAdapters.supports(TlsCapability.SystemTrust))
        @Expect(withAdapters.supports(TlsCapability.HardwareKeys))
        @Expect(withAdapters.supports(TlsCapability.NetworkBinding))
    }

    @TestCase
    func defaultSystemTrustFailsAtBuildUntilLinuxAdapterIsAvailable(): Unit {
        var observed = false
        try {
            let _ = TlsClientContext.builder(
                fullManifest(),
                TlsCapabilities.fromProvider(fullManifest())
            ).build()
        } catch (error: TlsContextException) {
            match (error.capability) {
                case Some(TlsCapability.SystemTrust) => observed = true
                case _ => ()
            }
        }
        @Expect(observed)
    }

    @TestCase
    func modernClientContextIsImmutableAndConcurrentShareable(): Unit {
        let manifest = fullManifest()
        let capabilities = TlsCapabilities.fromProvider(manifest)
        let input = ["h2", "http/1.1"]
        let context = TlsClientContext.builder(manifest, capabilities)
            .trust(testTrust())
            .alpn(input)
            .build()
        input[0] = "mutated"

        let firstCopy = context.alpnProtocols()
        firstCopy[0] = "also-mutated"
        @Expect(context.alpnProtocols()[0], "h2")
        @Expect(context.alpnProtocols()[1], "http/1.1")
        @Expect(isTls12(context.security.minimumVersion))
        @Expect(isTls13(context.security.maximumVersion))
        @Expect(!context.security.compressionEnabled)
        @Expect(!context.security.renegotiationEnabled)
        @Expect(!context.security.nullOrAnonymousCiphersEnabled)
        @Expect(!context.security.zeroRttEnabled)

        let tasks = ArrayList<Future<Bool>>()
        for (_ in 0..32) {
            tasks.add(spawn {
                let names = context.alpnProtocols()
                names.size == 2 && names[0] == "h2" &&
                    context.capabilities.supports(TlsCapability.Tls13)
            })
        }
        for (task in tasks) { @Expect(task.get(Duration.second)) }
    }

    @TestCase
    func strictTls13RejectsAnyTls12Override(): Unit {
        let manifest = fullManifest()
        let capabilities = TlsCapabilities.fromProvider(manifest)
        let strict = TlsClientContext.builder(manifest, capabilities)
            .securityProfile(TlsSecurityProfile.StrictTls13)
            .trust(testTrust())
            .build()
        @Expect(isTls13(strict.security.minimumVersion))
        @Expect(isTls13(strict.security.maximumVersion))

        var rejected = false
        try {
            let _ = TlsClientContext.builder(manifest, capabilities)
                .securityProfile(TlsSecurityProfile.StrictTls13)
                .versions(TlsVersion.Tls12, TlsVersion.Tls13)
                .trust(testTrust())
                .build()
        } catch (error: TlsContextException) {
            match (error.code) {
                case TlsContextErrorCode.InvalidVersionRange => rejected = true
                case _ => ()
            }
        }
        @Expect(rejected)
    }

    @TestCase
    func missingTls13AndHttp2CapabilitiesFailBeforeHandshake(): Unit {
        let noTls13 = fullManifest(bits: 0x1efu64)
        var tls13Rejected = false
        try {
            let _ = TlsClientContext.builder(
                noTls13,
                TlsCapabilities.fromProvider(noTls13)
            ).trust(testTrust()).build()
        } catch (error: TlsContextException) {
            match (error.capability) {
                case Some(TlsCapability.Tls13) => tls13Rejected = true
                case _ => ()
            }
        }
        @Expect(tls13Rejected)

        let noHttp2 = fullManifest(bits: 0x1dfu64)
        var http2Rejected = false
        try {
            let _ = TlsClientContext.builder(
                noHttp2,
                TlsCapabilities.fromProvider(noHttp2)
            ).trust(testTrust()).alpn(["h2"]).build()
        } catch (error: TlsContextException) {
            match (error.capability) {
                case Some(TlsCapability.Http2) => http2Rejected = true
                case _ => ()
            }
        }
        @Expect(http2Rejected)
    }

    @TestCase
    func alpnRejectsEmptyAndDuplicateProtocolNames(): Unit {
        let manifest = fullManifest()
        let capabilities = TlsCapabilities.fromProvider(manifest)
        for (values in [[""], ["h2", "h2"]]) {
            var rejected = false
            try {
                let _ = TlsClientContext.builder(manifest, capabilities)
                    .trust(testTrust())
                    .alpn(values)
                    .build()
            } catch (error: TlsContextException) {
                match (error.code) {
                    case TlsContextErrorCode.InvalidAlpn => rejected = true
                    case _ => ()
                }
            }
            @Expect(rejected)
        }
    }

    @TestCase
    func serverRequiresServerIdentityAndMtlSTrustAtBuildTime(): Unit {
        let manifest = fullManifest()
        let capabilities = TlsCapabilities.fromProvider(manifest)
        var missingIdentity = false
        try {
            let _ = TlsServerContext.builder(manifest, capabilities).build()
        } catch (error: TlsContextException) {
            match (error.code) {
                case TlsContextErrorCode.MissingIdentity => missingIdentity = true
                case _ => ()
            }
        }
        @Expect(missingIdentity)

        let serverIdentity = tlsTestLocalIdentity()
        try {
            var missingTrust = false
            try {
                let _ = TlsServerContext.builder(manifest, capabilities)
                    .identity(serverIdentity)
                    .clientAuthentication(ClientAuthentication.Required)
                    .build()
            } catch (error: TlsContextException) {
                match (error.code) {
                    case TlsContextErrorCode.MissingTrust => missingTrust = true
                    case _ => ()
                }
            }
            @Expect(missingTrust)

            let context = TlsServerContext.builder(manifest, capabilities)
                .identity(serverIdentity)
                .clientAuthentication(ClientAuthentication.Required)
                .clientTrust(testTrust())
                .alpn(["h2", "http/1.1"])
                .build()
            @Expect(context.alpnProtocols()[0], "h2")
        } finally {
            serverIdentity.privateKeyRef.close()
        }
    }

    @TestCase
    func clientIdentityCapabilityIsValidatedAtBuildTime(): Unit {
        let manifest = fullManifest(bits: 0x1fdu64)
        let identity = tlsTestLocalIdentity()
        var rejected = false
        try {
            try {
                let _ = TlsClientContext.builder(
                    manifest,
                    TlsCapabilities.fromProvider(manifest)
                ).trust(testTrust()).identity(identity).build()
            } catch (error: TlsContextException) {
                match (error.capability) {
                    case Some(TlsCapability.ClientCertificate) => rejected = true
                    case _ => ()
                }
            }
            @Expect(rejected)
        } finally {
            identity.privateKeyRef.close()
        }
    }
}

private func fullManifest(bits!: UInt64 = 0x1ffu64): TlsProviderManifest {
    TlsProviderManifest(
        "test-provider",
        "1",
        "fingerprint",
        "static",
        "test",
        bits
    )
}

private func testTrust(): TrustPolicy {
    TrustPolicy.pinnedPublicKeys([SpkiSha256Pin(Array<Byte>(32, repeat: 7))])
}

private func isTls12(value: TlsVersion): Bool {
    match (value) {
        case TlsVersion.Tls12 => true
        case _ => false
    }
}

private func isTls13(value: TlsVersion): Bool {
    match (value) {
        case TlsVersion.Tls13 => true
        case _ => false
    }
}
