package wirestack.internal.tls_engine

import std.collection.*
import std.fs.*
import std.process.*
import std.unittest.*
import std.unittest.testmacro.*
import wirestack.internal.common.*
import wirestack.internal.transport.*
import wirestack.internal.trust.*

@Test
class TlsEnginePumpTest {
    @TestCase
    func awsLcClientEngineProducesAClientHelloWithoutSocketIo(): Unit {
        let provider = AwsLcTlsProvider()
        let engine = provider.createEngine(
            TlsEngineRole.Client,
            TlsSecurityPolicy.forProfile(TlsSecurityProfile.Modern)
        )
        try {
            var wantsRead = false
            match (engine.handshakeStep()) {
                case TlsEngineStep.WantRead => wantsRead = true
                case _ => ()
            }
            @Expect(wantsRead)
            @Expect(engine.pendingCiphertext() > 0)
            let output = Array<Byte>(4096, repeat: 0)
            let count = engine.drainCiphertext(MutableByteSpan(output))
            @Expect(count > 5)
            @Expect(output[0], 22) // TLS handshake record content type.
        } finally {
            engine.close()
            provider.close()
        }
    }

    @TestCase
    func strictTls13PolicyIsAcceptedByTheNativeEngine(): Unit {
        let provider = AwsLcTlsProvider()
        let engine = provider.createEngine(
            TlsEngineRole.Client,
            TlsSecurityPolicy.forProfile(TlsSecurityProfile.StrictTls13)
        )
        try {
            var wantsRead = false
            match (engine.handshakeStep()) {
                case TlsEngineStep.WantRead => wantsRead = true
                case _ => ()
            }
            @Expect(wantsRead)
            @Expect(engine.pendingCiphertext() > 0)
        } finally {
            engine.close()
            provider.close()
        }
    }

    @TestCase
    func LinuxSystemTrustLoadsExplicitlyAndSniStaysSeparateFromReferenceIdentity(): Unit {
        let provider = AwsLcTlsProvider()
        let context = TlsClientContext.builder(provider.manifest(), provider.linuxCapabilities())
            .trust(TrustPolicy.system())
            .build()
        let engine = provider.createClientEngine(
            context,
            ReferenceIdentity.Dns(HostName("verify.example")),
            serverName: Some(HostName("sni.example"))
        )
        try {
            var wantsRead = false
            match (engine.handshakeStep()) {
                case TlsEngineStep.WantRead => wantsRead = true
                case _ => ()
            }
            @Expect(wantsRead)
            let output = Array<Byte>(4096, repeat: 0)
            let count = engine.drainCiphertext(MutableByteSpan(output))
            @Expect(containsAscii(output, count, "sni.example"))
            @Expect(!containsAscii(output, count, "verify.example"))
        } finally {
            engine.close()
            provider.close()
        }
    }

    @TestCase
    func customRootChainIsLoadedIntoARealAwsLcClientEngine(): Unit {
        let provider = AwsLcTlsProvider()
        let roots = CertificateChain([DerCertificate(tlsTestCertificateDer())])
        let context = TlsClientContext.builder(
            provider.manifest(),
            TlsCapabilities.fromProvider(provider.manifest())
        ).trust(TrustPolicy.customRoots(roots)).build()
        let engine = provider.createClientEngine(
            context,
            ReferenceIdentity.Dns(HostName("example.com")),
            serverName: Some(HostName("example.com"))
        )
        try {
            var wantsRead = false
            match (engine.handshakeStep()) {
                case TlsEngineStep.WantRead => wantsRead = true
                case _ => ()
            }
            @Expect(wantsRead)
            @Expect(engine.pendingCiphertext() > 0)
        } finally {
            engine.close()
            provider.close()
        }
    }

    @TestCase
    func spkiPinPolicyConfiguresTheNativeVerificationPathBeforeHandshake(): Unit {
        let provider = AwsLcTlsProvider()
        let pin = tlsTestSpkiPin()
        let context = TlsClientContext.builder(
            provider.manifest(),
            TlsCapabilities.fromProvider(provider.manifest())
        ).trust(TrustPolicy.pinnedPublicKeys([pin])).build()
        let engine = provider.createClientEngine(
            context,
            ReferenceIdentity.Dns(HostName("example.com")),
            serverName: Some(HostName("example.com"))
        )
        try {
            var wantsRead = false
            match (engine.handshakeStep()) {
                case TlsEngineStep.WantRead => wantsRead = true
                case _ => ()
            }
            @Expect(wantsRead)
            @Expect(engine.pendingCiphertext() > 0)
        } finally {
            engine.close()
            provider.close()
        }
    }

    @TestCase
    func matchingSpkiPinCompletesARealClientServerHandshake(): Unit {
        let provider = AwsLcTlsProvider()
        let identity = tlsTestLocalIdentity()
        let capabilities = provider.linuxCapabilities()
        let clientContext = TlsClientContext.builder(provider.manifest(), capabilities)
            .trust(TrustPolicy.pinnedPublicKeys([tlsTestSpkiPin()]))
            .build()
        let serverContext = TlsServerContext.builder(provider.manifest(), capabilities)
            .identity(identity)
            .build()
        let client = provider.createClientEngine(
            clientContext,
            ReferenceIdentity.Dns(HostName("example.com")),
            serverName: Some(HostName("example.com"))
        )
        let server = provider.createServerEngine(serverContext)
        try {
            drivePairedMemoryHandshake(client, server)
        } finally {
            client.close()
            server.close()
            identity.privateKeyRef.close()
            provider.close()
        }
    }

    @TestCase
    func matchingSpkiPinDoesNotBypassReferenceIdentityVerification(): Unit {
        let provider = AwsLcTlsProvider()
        let identity = tlsTestLocalIdentity()
        let capabilities = provider.linuxCapabilities()
        let clientContext = TlsClientContext.builder(provider.manifest(), capabilities)
            .trust(TrustPolicy.pinnedPublicKeys([tlsTestSpkiPin()]))
            .build()
        let serverContext = TlsServerContext.builder(provider.manifest(), capabilities)
            .identity(identity)
            .build()
        let client = provider.createClientEngine(
            clientContext,
            ReferenceIdentity.Dns(HostName("wrong.example")),
            serverName: Some(HostName("example.com"))
        )
        let server = provider.createServerEngine(serverContext)
        var rejected = false
        try {
            try {
                drivePairedMemoryHandshake(client, server)
            } catch (error: TlsEngineException) {
                match (error.tlsCode) {
                    case TlsEngineErrorCode.IdentityMismatch =>
                        rejected = isTlsHandshakePhase(error.phase) &&
                            isNeverRetryable(error.retryability) &&
                            error.verificationCode.isSome()
                    case _ => ()
                }
            }
            @Expect(rejected)
        } finally {
            client.close()
            server.close()
            identity.privateKeyRef.close()
            provider.close()
        }
    }

    @TestCase
    func realAwsLcEnginesExchangeCloseNotifyInBothDirections(): Unit {
        let provider = AwsLcTlsProvider()
        let identity = tlsTestLocalIdentity()
        let capabilities = provider.linuxCapabilities()
        let clientContext = TlsClientContext.builder(provider.manifest(), capabilities)
            .trust(TrustPolicy.pinnedPublicKeys([tlsTestSpkiPin()]))
            .build()
        let serverContext = TlsServerContext.builder(provider.manifest(), capabilities)
            .identity(identity)
            .build()
        let client = provider.createClientEngine(
            clientContext,
            ReferenceIdentity.Dns(HostName("example.com")),
            serverName: Some(HostName("example.com"))
        )
        let server = provider.createServerEngine(serverContext)
        try {
            drivePairedMemoryHandshake(client, server)
            match (client.shutdownStep()) {
                case TlsEngineShutdownResult.Sent => @Expect(true)
                case _ => @Fail("initiator must send close_notify before peer acknowledgement")
            }
            @Expect(transferCiphertext(client, server))
            match (server.shutdownStep()) {
                case TlsEngineShutdownResult.Sent => @Expect(true)
                case _ => @Fail("peer must answer close_notify before completing shutdown")
            }
            @Expect(transferCiphertext(server, client))
            match (client.shutdownStep()) {
                case TlsEngineShutdownResult.Complete => @Expect(true)
                case _ => @Fail("initiator must process the peer close_notify")
            }
            match (server.shutdownStep()) {
                case TlsEngineShutdownResult.Complete => @Expect(true)
                case _ => @Fail("peer must process the buffered initiator close_notify")
            }
        } finally {
            client.close()
            server.close()
            identity.privateKeyRef.close()
            provider.close()
        }
    }

    @TestCase
    func handshakeInfoReportsNegotiatedAlpnPeerChainAndVerificationEvidence(): Unit {
        let provider = AwsLcTlsProvider()
        let identity = tlsTestLocalIdentity()
        let capabilities = provider.linuxCapabilities()
        let clientContext = TlsClientContext.builder(provider.manifest(), capabilities)
            .trust(TrustPolicy.pinnedPublicKeys([tlsTestSpkiPin()]))
            .alpn(["http/1.1", "h2"])
            .build()
        let serverContext = TlsServerContext.builder(provider.manifest(), capabilities)
            .identity(identity)
            .alpn(["h2", "http/1.1"])
            .build()
        let client = provider.createClientEngine(
            clientContext,
            ReferenceIdentity.Dns(HostName("example.com")),
            serverName: Some(HostName("example.com"))
        )
        let server = provider.createServerEngine(serverContext)
        try {
            drivePairedMemoryHandshake(client, server)
            let clientInfo = requireHandshakeInfo(client)
            let serverInfo = requireHandshakeInfo(server)
            @Expect(clientInfo.cipherSuite.isEmpty(), false)
            @Expect(clientInfo.negotiatedAlpn, Some("h2"))
            @Expect(serverInfo.negotiatedAlpn, Some("h2"))
            @Expect(clientInfo.resumed, false)
            @Expect(clientInfo.providerManifest.providerId, "aws-lc")
            match (clientInfo.version) {
                case TlsVersion.Tls13 => ()
                case _ => @Fail("expected TLS 1.3 negotiation")
            }
            match (clientInfo.peerCertificateChain) {
                case Some(chain) => @Expect(chain.size(), 1)
                case None => @Fail("client handshake info must retain the peer chain")
            }
            match (clientInfo.verificationEvidence) {
                case Some(evidence) =>
                    @Expect(evidence.peerChainLength, 1)
                    @Expect(evidence.matchedPinIndex, Some(0))
                    @Expect(evidence.verifiedReferenceIdentity, Some("example.com"))
                    match (evidence.status) {
                        case TrustVerificationStatus.Verified => ()
                        case _ => @Fail("expected verified trust evidence")
                    }
                case None => @Fail("client handshake info must retain verification evidence")
            }
            @Expect(serverInfo.peerCertificateChain.isNone())
        } finally {
            client.close()
            server.close()
            identity.privateKeyRef.close()
            provider.close()
        }
    }

    @TestCase
    func tls13TicketResumesAcrossFreshEnginesWithoutEarlyData(): Unit {
        proveRealSessionResumption(TlsVersion.Tls13, TlsVersion.Tls13, true)
    }

    @TestCase
    func tls12TicketResumesAcrossFreshEngines(): Unit {
        proveRealSessionResumption(TlsVersion.Tls12, TlsVersion.Tls12, false)
    }

    @TestCase
    func sniSelectsTheCompleteImmutableContextAndItsCertificate(): Unit {
        let provider = AwsLcTlsProvider()
        let primaryIdentity = tlsTestLocalIdentity()
        let alternateIdentity = tlsAltTestLocalIdentity()
        let capabilities = provider.linuxCapabilities()
        let primaryContext = TlsServerContext.builder(provider.manifest(), capabilities)
            .identity(primaryIdentity)
            .alpn(["http/1.1"])
            .build()
        let alternateContext = TlsServerContext.builder(provider.manifest(), capabilities)
            .identity(alternateIdentity)
            .securityProfile(TlsSecurityProfile.StrictTls13)
            .alpn(["h2"])
            .build()
        let selector = TlsServerContextSelector([
            TlsServerNameRoute(HostName("example.com"), primaryContext),
            TlsServerNameRoute(HostName("alt.example.com"), alternateContext)
        ])
        let clientContext = TlsClientContext.builder(provider.manifest(), capabilities)
            .trust(TrustPolicy.customRoots(CertificateChain([
                DerCertificate(tlsAltTestCertificateDer())
            ])))
            .alpn(["http/1.1", "h2"])
            .build()
        let client = provider.createClientEngine(
            clientContext,
            ReferenceIdentity.Dns(HostName("alt.example.com")),
            serverName: Some(HostName("alt.example.com"))
        )
        let server = provider.createServerEngine(selector)
        try {
            drivePairedMemoryHandshake(client, server)
            let clientInfo = requireHandshakeInfo(client)
            let serverInfo = requireHandshakeInfo(server)
            @Expect(clientInfo.negotiatedAlpn, Some("h2"))
            @Expect(serverInfo.negotiatedAlpn, Some("h2"))
            @Expect(serverInfo.requestedServerName, Some("alt.example.com"))
            match (clientInfo.peerCertificateChain) {
                case Some(chain) =>
                    @Expect(chain.certificateAt(0).derBytes(), tlsAltTestCertificateDer())
                case None => @Fail("SNI-selected server must return its selected certificate")
            }
            match (clientInfo.version) {
                case TlsVersion.Tls13 => ()
                case _ => @Fail("selected StrictTls13 context must control protocol policy")
            }
        } finally {
            client.close()
            server.close()
            primaryIdentity.privateKeyRef.close()
            alternateIdentity.privateKeyRef.close()
            provider.close()
        }
    }

    @TestCase
    func sniSelectorRejectsMissingAndUnknownNamesWithStableEvidence(): Unit {
        for (name in [None<HostName>, Some(HostName("unknown.example.com"))]) {
            let provider = AwsLcTlsProvider()
            let identity = tlsTestLocalIdentity()
            let capabilities = provider.linuxCapabilities()
            let context = TlsServerContext.builder(provider.manifest(), capabilities)
                .identity(identity)
                .build()
            let selector = TlsServerContextSelector([
                TlsServerNameRoute(HostName("example.com"), context)
            ])
            let clientContext = TlsClientContext.builder(provider.manifest(), capabilities)
                .trust(TrustPolicy.pinnedPublicKeys([tlsTestSpkiPin()]))
                .build()
            let client = provider.createClientEngine(
                clientContext,
                ReferenceIdentity.Dns(HostName("example.com")),
                serverName: name
            )
            let server = provider.createServerEngine(selector)
            var selectionCode = None<TlsServerNameSelectionErrorCode>
            try {
                try {
                    drivePairedMemoryHandshake(client, server)
                } catch (error: TlsEngineException) {
                    match (error.cause) {
                        case Some(cause: TlsServerNameSelectionException) =>
                            selectionCode = Some(cause.code)
                        case _ => ()
                    }
                }
                match ((name, selectionCode)) {
                    case (None, Some(TlsServerNameSelectionErrorCode.MissingServerName)) => ()
                    case (Some(_), Some(TlsServerNameSelectionErrorCode.NoMatchingServerName)) => ()
                    case _ => @Fail("SNI rejection did not retain its stable selection code")
                }
            } finally {
                client.close()
                server.close()
                identity.privateKeyRef.close()
                provider.close()
            }
        }
    }

    @TestCase
    func noSharedAlpnFailsTheHandshakeInsteadOfSilentlySelectingNothing(): Unit {
        let provider = AwsLcTlsProvider()
        let identity = tlsTestLocalIdentity()
        let capabilities = provider.linuxCapabilities()
        let clientContext = TlsClientContext.builder(provider.manifest(), capabilities)
            .trust(TrustPolicy.pinnedPublicKeys([tlsTestSpkiPin()]))
            .alpn(["http/1.1"])
            .build()
        let serverContext = TlsServerContext.builder(provider.manifest(), capabilities)
            .identity(identity)
            .alpn(["h2"])
            .build()
        let client = provider.createClientEngine(
            clientContext,
            ReferenceIdentity.Dns(HostName("example.com"))
        )
        let server = provider.createServerEngine(serverContext)
        var failed = false
        try {
            try {
                drivePairedMemoryHandshake(client, server)
            } catch (error: TlsEngineException) {
                match (error.tlsCode) {
                    case TlsEngineErrorCode.NoSharedAlpn =>
                        failed = isTlsHandshakePhase(error.phase) &&
                            isNeverRetryable(error.retryability)
                    case _ => ()
                }
            }
            @Expect(failed)
        } finally {
            client.close()
            server.close()
            identity.privateKeyRef.close()
            provider.close()
        }
    }

    @TestCase
    func requiredMutualTlsUsesClientIdentityAndReturnsServerVerificationEvidence(): Unit {
        let provider = AwsLcTlsProvider()
        let identity = tlsTestLocalIdentity()
        let capabilities = provider.linuxCapabilities()
        let pinned = TrustPolicy.pinnedPublicKeys([tlsTestSpkiPin()])
        let clientContext = TlsClientContext.builder(provider.manifest(), capabilities)
            .trust(pinned)
            .identity(identity)
            .build()
        let serverContext = TlsServerContext.builder(provider.manifest(), capabilities)
            .identity(identity)
            .clientAuthentication(ClientAuthentication.Required)
            .clientTrust(pinned)
            .build()
        let client = provider.createClientEngine(
            clientContext,
            ReferenceIdentity.Dns(HostName("example.com"))
        )
        let server = provider.createServerEngine(serverContext)
        try {
            drivePairedMemoryHandshake(client, server)
            let serverInfo = requireHandshakeInfo(server)
            match (serverInfo.peerCertificateChain) {
                case Some(chain) => @Expect(chain.size(), 1)
                case None => @Fail("required mTLS must retain the client certificate chain")
            }
            match (serverInfo.verificationEvidence) {
                case Some(evidence) =>
                    @Expect(evidence.peerChainLength, 1)
                    @Expect(evidence.matchedPinIndex, Some(0))
                case None => @Fail("required mTLS must retain client verification evidence")
            }
        } finally {
            client.close()
            server.close()
            identity.privateKeyRef.close()
            provider.close()
        }
    }

    @TestCase
    func requiredMutualTlsRejectsMissingClientIdentityButOptionalAllowsIt(): Unit {
        let provider = AwsLcTlsProvider()
        let identity = tlsTestLocalIdentity()
        let capabilities = provider.linuxCapabilities()
        let pinned = TrustPolicy.pinnedPublicKeys([tlsTestSpkiPin()])
        let clientContext = TlsClientContext.builder(provider.manifest(), capabilities)
            .trust(pinned)
            .build()
        let requiredContext = TlsServerContext.builder(provider.manifest(), capabilities)
            .identity(identity)
            .clientAuthentication(ClientAuthentication.Required)
            .clientTrust(pinned)
            .build()
        let requiredClient = provider.createClientEngine(
            clientContext,
            ReferenceIdentity.Dns(HostName("example.com"))
        )
        let requiredServer = provider.createServerEngine(requiredContext)
        var rejected = false
        try {
            try {
                drivePairedMemoryHandshake(requiredClient, requiredServer)
            } catch (error: TlsEngineException) {
                match (error.tlsCode) {
                    case TlsEngineErrorCode.ClientCertificateRequired =>
                        rejected = isTlsHandshakePhase(error.phase) &&
                            isNeverRetryable(error.retryability)
                    case _ => ()
                }
            }
            @Expect(rejected)
        } finally {
            requiredClient.close()
            requiredServer.close()
        }

        let optionalContext = TlsServerContext.builder(provider.manifest(), capabilities)
            .identity(identity)
            .clientAuthentication(ClientAuthentication.Optional)
            .clientTrust(pinned)
            .build()
        let optionalClient = provider.createClientEngine(
            clientContext,
            ReferenceIdentity.Dns(HostName("example.com"))
        )
        let optionalServer = provider.createServerEngine(optionalContext)
        try {
            drivePairedMemoryHandshake(optionalClient, optionalServer)
            let info = requireHandshakeInfo(optionalServer)
            @Expect(info.peerCertificateChain.isNone())
            @Expect(info.verificationEvidence.isNone())
        } finally {
            optionalClient.close()
            optionalServer.close()
            identity.privateKeyRef.close()
            provider.close()
        }
    }

    @TestCase
    func mismatchedSpkiPinFailsARealClientServerHandshake(): Unit {
        let provider = AwsLcTlsProvider()
        let identity = tlsTestLocalIdentity()
        let capabilities = provider.linuxCapabilities()
        let wrongPin = SpkiSha256Pin(Array<Byte>(32, repeat: 0))
        let clientContext = TlsClientContext.builder(provider.manifest(), capabilities)
            .trust(TrustPolicy.pinnedPublicKeys([wrongPin]))
            .build()
        let serverContext = TlsServerContext.builder(provider.manifest(), capabilities)
            .identity(identity)
            .build()
        let client = provider.createClientEngine(
            clientContext,
            ReferenceIdentity.Dns(HostName("example.com")),
            serverName: Some(HostName("example.com"))
        )
        let server = provider.createServerEngine(serverContext)
        var rejected = false
        try {
            try {
                drivePairedMemoryHandshake(client, server)
            } catch (error: TlsEngineException) {
                match (error.tlsCode) {
                    case TlsEngineErrorCode.CertificateUntrusted =>
                        rejected = isTlsHandshakePhase(error.phase) &&
                            isNeverRetryable(error.retryability) &&
                            error.nativeCode.isSome() && error.verificationCode.isSome()
                    case _ => ()
                }
            }
            @Expect(rejected)
        } finally {
            client.close()
            server.close()
            identity.privateKeyRef.close()
            provider.close()
        }
    }

    @TestCase
    func externalSignerCompletesARealHandshakeOutsideTheNativeCallback(): Unit {
        let provider = AwsLcTlsProvider()
        let signer = OpenSslProcessTestSigner()
        let key = PrivateKeyRef.externalSigner(
            "test-process-signer",
            tlsTestSubjectPublicKeyInfoDer(),
            signer
        )
        let identity = LocalIdentity(
            CertificateChain([DerCertificate(tlsTestCertificateDer())]),
            key
        )
        let capabilities = provider.linuxCapabilities()
        let clientContext = TlsClientContext.builder(provider.manifest(), capabilities)
            .trust(TrustPolicy.pinnedPublicKeys([tlsTestSpkiPin()]))
            .build()
        let serverContext = TlsServerContext.builder(provider.manifest(), capabilities)
            .identity(identity)
            .build()
        let client = provider.createClientEngine(
            clientContext,
            ReferenceIdentity.Dns(HostName("example.com")),
            serverName: Some(HostName("example.com"))
        )
        let server = provider.createServerEngine(serverContext)
        try {
            drivePairedMemoryHandshake(client, server)
            @Expect(signer.calls > 0)
        } finally {
            client.close()
            server.close()
            key.close()
            provider.close()
        }
    }

    @TestCase
    func externalSignerExceptionFailsClosedWithoutCrossingTheCAbi(): Unit {
        let provider = AwsLcTlsProvider()
        let key = PrivateKeyRef.externalSigner(
            "throwing-signer",
            tlsTestSubjectPublicKeyInfoDer(),
            ThrowingTestSigner()
        )
        let identity = LocalIdentity(
            CertificateChain([DerCertificate(tlsTestCertificateDer())]),
            key
        )
        let capabilities = provider.linuxCapabilities()
        let clientContext = TlsClientContext.builder(provider.manifest(), capabilities)
            .trust(TrustPolicy.pinnedPublicKeys([tlsTestSpkiPin()]))
            .build()
        let serverContext = TlsServerContext.builder(provider.manifest(), capabilities)
            .identity(identity)
            .build()
        let client = provider.createClientEngine(
            clientContext,
            ReferenceIdentity.Dns(HostName("example.com"))
        )
        let server = provider.createServerEngine(serverContext)
        var rejected = false
        try {
            try {
                drivePairedMemoryHandshake(client, server)
            } catch (error: TlsEngineException) {
                match (error.tlsCode) {
                    case TlsEngineErrorCode.PrivateKeyFailure =>
                        rejected = error.cause.isSome()
                    case _ => ()
                }
            }
            @Expect(rejected)
        } finally {
            client.close()
            server.close()
            key.close()
            provider.close()
        }
    }

    @TestCase
    func cancellationBeforeSignerInvocationFailsThePendingNativeOperation(): Unit {
        let provider = AwsLcTlsProvider()
        let signer = OpenSslProcessTestSigner()
        let key = PrivateKeyRef.externalSigner(
            "cancelled-signer",
            tlsTestSubjectPublicKeyInfoDer(),
            signer
        )
        let identity = LocalIdentity(
            CertificateChain([DerCertificate(tlsTestCertificateDer())]),
            key
        )
        let capabilities = provider.linuxCapabilities()
        let client = provider.createClientEngine(
            TlsClientContext.builder(provider.manifest(), capabilities)
                .trust(TrustPolicy.pinnedPublicKeys([tlsTestSpkiPin()]))
                .build(),
            ReferenceIdentity.Dns(HostName("example.com"))
        )
        let server = provider.createServerEngine(
            TlsServerContext.builder(provider.manifest(), capabilities)
                .identity(identity)
                .build()
        )
        let cancellation = CancellationSource()
        var cancelled = false
        var nativeFailed = false
        try {
            advanceToServerSignatureRequest(client, server)
            cancellation.cancel()
            try {
                match (server) {
                    case signing: ExternalSigningTlsEngine =>
                        signing.serviceExternalSignature(
                            OperationContext(cancellation: cancellation.token)
                        )
                    case _ => ()
                }
            } catch (error: NetworkException) {
                match (error.code) {
                    case NetworkErrorCode.Cancelled => cancelled = true
                    case _ => ()
                }
            }
            try {
                let _ = server.handshakeStep()
            } catch (error: TlsEngineException) {
                match (error.tlsCode) {
                    case TlsEngineErrorCode.PrivateKeyFailure => nativeFailed = true
                    case _ => ()
                }
            }
            @Expect(cancelled)
            @Expect(signer.calls, 0)
            @Expect(nativeFailed)
        } finally {
            client.close()
            server.close()
            key.close()
            provider.close()
        }
    }

    @TestCase
    func pumpHandlesWantReadWriteAndPartialIoWithBoundedBuffers(): Unit {
        let engine = ScriptedEngine()
        let transport = ScriptedTransport([7, 6, 5], readChunk: 2, writeChunk: 2)

        TlsEnginePump(ciphertextChunkSize: 3).driveHandshake(engine, transport)

        @Expect(transport.written.size, 7)
        @Expect(transport.written[0], 1)
        @Expect(transport.written[4], 5)
        @Expect(transport.written[5], 9)
        @Expect(transport.written[6], 8)
        @Expect(engine.fed.size, 2)
        @Expect(engine.fed[0], 7)
        @Expect(engine.fed[1], 6)
        @Expect(transport.maxRequestedRead, 3)
        @Expect(transport.maxRequestedWrite <= 3)
    }

    @TestCase
    func wantWriteWithoutCiphertextFailsInsteadOfSpinning(): Unit {
        let engine = StalledEngine(TlsEngineStep.WantWrite)
        let transport = ScriptedTransport([])
        var observed = false

        try {
            TlsEnginePump().driveHandshake(engine, transport)
        } catch (error: TlsEngineException) {
            match (error.tlsCode) {
                case TlsEngineErrorCode.NoProgress => observed = true
                case _ => ()
            }
        }
        @Expect(observed)
        @Expect(engine.steps, 1)
    }

    @TestCase
    func eofDuringWantReadRetainsTlsHandshakeEvidence(): Unit {
        let engine = StalledEngine(TlsEngineStep.WantRead)
        let transport = ScriptedTransport([])
        var observed = false

        try {
            TlsEnginePump().driveHandshake(engine, transport)
        } catch (error: TlsEngineException) {
            match (error.tlsCode) {
                case TlsEngineErrorCode.PeerClosedWithoutCloseNotify =>
                    match (error.phase) {
                        case NetworkPhase.TlsHandshake => observed = true
                        case _ => ()
                    }
                case _ => ()
            }
        }
        @Expect(observed)
    }

    @TestCase
    func preCancellationStopsBeforeCallingProviderOrTransport(): Unit {
        let source = CancellationSource()
        source.cancel()
        let engine = StalledEngine(TlsEngineStep.WantRead)
        let transport = ScriptedTransport([1])
        var cancelled = false

        try {
            TlsEnginePump().driveHandshake(
                engine,
                transport,
                context: OperationContext(cancellation: source.token)
            )
        } catch (error: TlsEngineException) {
            match (error.tlsCode) {
                case TlsEngineErrorCode.HandshakeCancelled =>
                    cancelled = isTlsHandshakePhase(error.phase) &&
                        isNeverRetryable(error.retryability)
                case _ => ()
            }
        }
        @Expect(cancelled)
        @Expect(engine.steps, 0)
        @Expect(transport.readCalls, 0)
        @Expect(transport.writeCalls, 0)
    }

    @TestCase
    func expiredDeadlineStopsBeforeCallingProviderOrTransport(): Unit {
        let engine = StalledEngine(TlsEngineStep.WantRead)
        let transport = ScriptedTransport([1])
        var timedOut = false

        try {
            TlsEnginePump().driveHandshake(
                engine,
                transport,
                context: OperationContext(deadline: Some(Deadline.after(Duration.Zero)))
            )
        } catch (error: TlsEngineException) {
            match (error.tlsCode) {
                case TlsEngineErrorCode.HandshakeTimeout =>
                    timedOut = isTlsHandshakePhase(error.phase)
                case _ => ()
            }
        }
        @Expect(timedOut)
        @Expect(engine.steps, 0)
        @Expect(transport.readCalls, 0)
        @Expect(transport.writeCalls, 0)
    }
}

private func isTlsHandshakePhase(value: NetworkPhase): Bool {
    match (value) {
        case NetworkPhase.TlsHandshake => true
        case _ => false
    }
}

private func isNeverRetryable(value: Retryability): Bool {
    match (value) {
        case Retryability.Never => true
        case _ => false
    }
}


private func containsAscii(buffer: Array<Byte>, length: Int64, needle: String): Bool {
    let bytes = needle.toArray()
    if (bytes.isEmpty() || length < bytes.size) { return false }
    for (start in 0..(length - bytes.size + 1)) {
        var equal = true
        for (index in 0..bytes.size) {
            if (buffer[start + index] != bytes[index]) {
                equal = false
                break
            }
        }
        if (equal) { return true }
    }
    false
}

private func proveRealSessionResumption(
    minimum: TlsVersion,
    maximum: TlsVersion,
    expectSingleUse: Bool
): Unit {
    let provider = AwsLcTlsProvider()
    let identity = tlsTestLocalIdentity()
    let capabilities = provider.linuxCapabilities()
    let clientContext = TlsClientContext.builder(provider.manifest(), capabilities)
        .trust(TrustPolicy.pinnedPublicKeys([tlsTestSpkiPin()]))
        .versions(minimum, maximum)
        .alpn(["h2"])
        .build()
    let serverContext = TlsServerContext.builder(provider.manifest(), capabilities)
        .identity(identity)
        .versions(minimum, maximum)
        .alpn(["h2"])
        .build()
    let firstClient = provider.createClientEngine(
        clientContext,
        ReferenceIdentity.Dns(HostName("example.com")),
        serverName: Some(HostName("example.com"))
    )
    let firstServer = provider.createServerEngine(serverContext)
    try {
        drivePairedMemoryHandshake(firstClient, firstServer)
        let scratch = Array<Byte>(1, repeat: 0)
        let _ = firstClient.readPlaintext(MutableByteSpan(scratch))
        @Expect(provider.sessionStoreSnapshot().entries, 1)
    } finally {
        firstClient.close()
        firstServer.close()
    }
    let resumedClient = provider.createClientEngine(
        clientContext,
        ReferenceIdentity.Dns(HostName("example.com")),
        serverName: Some(HostName("example.com"))
    )
    @Expect(provider.sessionStoreSnapshot().entries, if (expectSingleUse) { 0 } else { 1 })
    let resumedServer = provider.createServerEngine(serverContext)
    try {
        drivePairedMemoryHandshake(resumedClient, resumedServer)
        @Expect(requireHandshakeInfo(resumedClient).resumed)
        @Expect(requireHandshakeInfo(resumedServer).resumed)
        @Expect(clientContext.security.zeroRttEnabled, false)
    } finally {
        resumedClient.close()
        resumedServer.close()
        identity.privateKeyRef.close()
        provider.close()
    }
}

private func drivePairedMemoryHandshake(client: TlsEngine, server: TlsEngine): Unit {
    for (_ in 0..128) {
        let clientStep = client.handshakeStep()
        serviceEngineRequestIfNeeded(client, clientStep)
        let clientMoved = transferCiphertext(client, server)
        let serverStep = server.handshakeStep()
        serviceEngineRequestIfNeeded(server, serverStep)
        let serverMoved = transferCiphertext(server, client)
        if (isHandshakeComplete(clientStep) && isHandshakeComplete(serverStep)) {
            return
        }
        if (!clientMoved && !serverMoved &&
            isHandshakeReadBlocked(clientStep) && isHandshakeReadBlocked(serverStep)) {
            throw TlsEngineException(
                TlsEngineErrorCode.NoProgress,
                "paired TLS memory handshake made no progress"
            )
        }
    }
    throw TlsEngineException(
        TlsEngineErrorCode.NoProgress,
        "paired TLS memory handshake exceeded its step bound"
    )
}

private func requireHandshakeInfo(engine: TlsEngine): TlsHandshakeInfo {
    match (engine) {
        case value: HandshakeInfoTlsEngine => value.handshakeInfo()
        case _ => throw IllegalStateException("test TLS engine exposes no handshake info")
    }
}

private func advanceToServerSignatureRequest(
    client: TlsEngine,
    server: TlsEngine
): Unit {
    for (_ in 0..32) {
        let clientStep = client.handshakeStep()
        serviceEngineRequestIfNeeded(client, clientStep)
        let _ = transferCiphertext(client, server)
        let serverStep = server.handshakeStep()
        match (serverStep) {
            case TlsEngineStep.NeedSignature => return
            case _ => ()
        }
        let _ = transferCiphertext(server, client)
    }
    throw TlsEngineException(
        TlsEngineErrorCode.NoProgress,
        "server did not request an external signature"
    )
}

private func serviceEngineRequestIfNeeded(
    engine: TlsEngine,
    step: TlsEngineStep
): Unit {
    match (step) {
        case TlsEngineStep.NeedSignature => match (engine) {
            case signing: ExternalSigningTlsEngine =>
                signing.serviceExternalSignature(OperationContext.background())
            case _ => throw TlsEngineException(
                TlsEngineErrorCode.PrivateKeyFailure,
                "test engine cannot service external signature"
            )
        }
        case TlsEngineStep.NeedServerSelection => match (engine) {
            case selecting: ServerNameSelectingTlsEngine =>
                selecting.serviceServerNameSelection(OperationContext.background())
            case _ => throw TlsEngineException(
                TlsEngineErrorCode.ServerNameSelectionFailure,
                "test engine cannot service SNI selection"
            )
        }
        case _ => ()
    }
}

private func transferCiphertext(source: TlsEngine, destination: TlsEngine): Bool {
    let buffer = Array<Byte>(16 * 1024, repeat: 0)
    var moved = false
    while (source.pendingCiphertext() > 0) {
        let count = source.drainCiphertext(MutableByteSpan(buffer))
        var offset: Int64 = 0
        while (offset < count) {
            let written = destination.feedCiphertext(
                ByteSpan(buffer, offset: offset, length: count - offset)
            )
            if (written <= 0) {
                throw TlsEngineException(
                    TlsEngineErrorCode.NoProgress,
                    "paired TLS memory transport accepted no ciphertext"
                )
            }
            offset += written
        }
        moved = true
    }
    moved
}

private func isHandshakeComplete(value: TlsEngineStep): Bool {
    match (value) {
        case TlsEngineStep.Complete => true
        case _ => false
    }
}

private func isHandshakeReadBlocked(value: TlsEngineStep): Bool {
    match (value) {
        case TlsEngineStep.WantRead => true
        case _ => false
    }
}

private class ScriptedEngine <: TlsEngine {
    let fed = ArrayList<Byte>()
    private let outgoing = ArrayList<Byte>()
    private var stepNumber: Int64 = 0

    public func handshakeStep(): TlsEngineStep {
        stepNumber++
        if (stepNumber == 1) {
            let values: Array<Byte> = [1, 2, 3, 4, 5]
            for (value in values) { outgoing.add(value) }
            return TlsEngineStep.WantWrite
        }
        if (fed.isEmpty()) {
            return TlsEngineStep.WantRead
        }
        let values: Array<Byte> = [9, 8]
        for (value in values) { outgoing.add(value) }
        TlsEngineStep.Complete
    }

    public func pendingCiphertext(): Int64 { outgoing.size }

    public func drainCiphertext(destination: MutableByteSpan): Int64 {
        let count = min(min(destination.length, outgoing.size), 2)
        for (index in 0..count) {
            destination.bytes[destination.offset + index] = outgoing.remove(at: 0)
        }
        count
    }

    public func feedCiphertext(source: ByteSpan): Int64 {
        let count = min(source.length, 1)
        for (index in 0..count) { fed.add(source.bytes[source.offset + index]) }
        count
    }

    public func readPlaintext(_: MutableByteSpan): TlsEngineReadResult {
        TlsEngineReadResult.PeerClosed
    }

    public func writePlaintext(_: ByteSpan): TlsEngineWriteResult {
        TlsEngineWriteResult.PeerClosed
    }

    public func shutdownStep(): TlsEngineShutdownResult {
        TlsEngineShutdownResult.Complete
    }

    public func close(): Unit {}
    public func isClosed(): Bool { false }
}

private class StalledEngine <: TlsEngine {
    private let result: TlsEngineStep
    var steps: Int64 = 0

    init(result: TlsEngineStep) { this.result = result }

    public func handshakeStep(): TlsEngineStep { steps++; result }
    public func pendingCiphertext(): Int64 { 0 }
    public func drainCiphertext(_: MutableByteSpan): Int64 { 0 }
    public func feedCiphertext(_: ByteSpan): Int64 { 0 }
    public func readPlaintext(_: MutableByteSpan): TlsEngineReadResult {
        TlsEngineReadResult.PeerClosed
    }
    public func writePlaintext(_: ByteSpan): TlsEngineWriteResult {
        TlsEngineWriteResult.PeerClosed
    }
    public func shutdownStep(): TlsEngineShutdownResult {
        TlsEngineShutdownResult.Complete
    }
    public func close(): Unit {}
    public func isClosed(): Bool { false }
}

private class OpenSslProcessTestSigner <: ExternalSigner {
    var calls: Int64 = 0

    public func supportedAlgorithms(): Array<TlsSignatureAlgorithm> {
        [TlsSignatureAlgorithm.RsaPssRsaeSha256]
    }

    public func sign(
        request: ExternalSignatureRequest,
        _: OperationContext
    ): Array<Byte> {
        let keyFile = File.createTemp("/tmp")
        let inputFile = File.createTemp("/tmp")
        let outputFile = File.createTemp("/tmp")
        let keyPath = keyFile.info.path.toString()
        let inputPath = inputFile.info.path.toString()
        let outputPath = outputFile.info.path.toString()
        keyFile.close()
        inputFile.close()
        outputFile.close()
        try {
            File.writeTo(keyPath, tlsTestPrivateKeyDer())
            File.writeTo(inputPath, request.messageBytes())
            let status = execute(
                "/usr/bin/openssl",
                [
                    "dgst", "-sha256", "-sign", keyPath, "-keyform", "DER",
                    "-sigopt", "rsa_padding_mode:pss",
                    "-sigopt", "rsa_pss_saltlen:digest",
                    "-out", outputPath, inputPath
                ]
            )
            if (status != 0) {
                throw IllegalStateException("test external signer process failed")
            }
            calls++
            File.readFrom(outputPath)
        } finally {
            remove(keyPath)
            remove(inputPath)
            remove(outputPath)
        }
    }
}

private class ThrowingTestSigner <: ExternalSigner {
    public func supportedAlgorithms(): Array<TlsSignatureAlgorithm> {
        [TlsSignatureAlgorithm.RsaPssRsaeSha256]
    }

    public func sign(
        _: ExternalSignatureRequest,
        _: OperationContext
    ): Array<Byte> {
        throw IllegalStateException("deliberate signer failure")
    }
}

private class ScriptedTransport <: DuplexTransport {
    private let incoming: ArrayList<Byte>
    private let readChunk: Int64
    private let writeChunk: Int64
    let written = ArrayList<Byte>()
    var readCalls: Int64 = 0
    var writeCalls: Int64 = 0
    var maxRequestedRead: Int64 = 0
    var maxRequestedWrite: Int64 = 0

    init(
        input: Array<Byte>,
        readChunk!: Int64 = 16 * 1024,
        writeChunk!: Int64 = 16 * 1024
    ) {
        incoming = ArrayList<Byte>()
        for (value in input) { incoming.add(value) }
        this.readChunk = readChunk
        this.writeChunk = writeChunk
    }

    public prop info: TransportInfo {
        get() { TransportInfo("tls-pump-test", runtimeIoBackend: "deterministic") }
    }

    public func readSome(
        destination: MutableByteSpan,
        context!: OperationContext = OperationContext.background()
    ): ReadResult {
        let _ = context
        readCalls++
        maxRequestedRead = max(maxRequestedRead, destination.length)
        if (incoming.isEmpty()) { return ReadResult.EndOfStream }
        let count = min(min(destination.length, incoming.size), readChunk)
        for (index in 0..count) {
            destination.bytes[destination.offset + index] = incoming.remove(at: 0)
        }
        ReadResult.Data(count)
    }

    public func writeSome(
        source: ByteSpan,
        context!: OperationContext = OperationContext.background()
    ): Int64 {
        let _ = context
        writeCalls++
        maxRequestedWrite = max(maxRequestedWrite, source.length)
        let count = min(source.length, writeChunk)
        for (index in 0..count) { written.add(source.bytes[source.offset + index]) }
        count
    }

    public func shutdown(_: ShutdownDirection): Unit {}
    public func close(_: OperationContext): Unit {}
    public func close(): Unit {}
    public func abort(reason!: ?AbortReason = None<AbortReason>): Unit { let _ = reason }
    public func isClosed(): Bool { false }
}
