# Linux delivery status

This file tracks the Linux-first profile accepted by
[ADR-0002](../architecture/adr/0002-linux-first-delivery-profile.md). The
global six-platform status remains in [`status.md`](status.md).

Status values have the same fail-closed meaning as the global status file.

## M0 Linux exit

| Area | Status | Current evidence or next requirement |
|---|---|---|
| Architecture and gate harness | COMPLETE | M0-001 through M0-004 and M0-018 evidence |
| close/wakeup and absolute Deadline | COMPLETE | M0-006 and M0-008 native Linux results |
| duplex and EOF classification | BLOCKED | Executed behavior passes; public typed half-close is absent and requires UP-003 |
| large-buffer/copy profile | BLOCKED | Large-buffer behavior passes; copied-byte/allocation instrumentation and adapter comparison remain |
| leak/soak | BLOCKED | Bounded stress passes; 100k cleanup and 24-hour Linux soak remain |
| DNS scheduler behavior | COMPLETE | M0-013 records starvation and mandates a bounded resolver pool |
| TLS provider | COMPLETE | AWS-LC 5.5.0 is selected by ADR-0003 after schema-v2 glibc/musl PASS results, executed external signing and 10,000 cleanup cycles |
| Transport SPI | IN_PROGRESS | Core types are implemented; listener, lifecycle closure and upstream capability mapping remain |
| Linux continuous gates | BLOCKED | Depends on the remaining Linux M0 evidence and decisions |

## Implemented Transport Core

| Task | Status | Evidence |
|---|---|---|
| M1-002 `ByteSpan`/`MutableByteSpan` | COMPLETE | Checked zero-copy ranges, slice/advance and tests |
| M1-003 monotonic `Deadline` | COMPLETE | `MonoTime`, injected clock, remaining/expiry/child tests |
| M1-004 cancellation primitive | IN_PROGRESS | Registration, unregister, fast-fail and exactly-once tests pass; larger race matrix remains |
| M1-005 `OperationContext` | COMPLETE | Immutable Deadline/cancellation/trace propagation tests |
| M1-006 trace context | IN_PROGRESS | Bounded read-only identifiers exist; event sink remains |
| M1-007 structured network error | COMPLETE | category/phase/code/retryability/native/endpoint/cause model and tests |
| M1-010 `DuplexTransport` contract | IN_PROGRESS | Contract and MemoryTransport semantics exist; shared lifecycle state machine remains |
| M1-011 `writeAll`/`readExact` | COMPLETE | Partial I/O, empty range and premature EOF tests |
| M1-012 `TransportListener` | COMPLETE | Contract plus bounded `StdNetTransportListener`; Deadline/cancel/close wakeup integration tests |
| M1-013 `MemoryTransport` | IN_PROGRESS | Bounded duplex, backpressure, half-close, EOF, cancellation and terminal tests pass; listener/fault scripting remains |
| M1-015/016 `StdNetTransport` ownership/connect | COMPLETE | DNS-free `IPSocketAddress` construction, exclusive adapter ownership, absolute connect budget and actual endpoints |
| M1-017 `StdNetTransport.readSome` | COMPLETE | Partial reads, peer EOF, local close/cancel distinction, Deadline and one-reader guard tested on Linux loopback |
| M1-018 bounded write staging | IN_PROGRESS | Bounded partial writes and copied-byte counters exist; current whole-Array `std.net` API still forces per-call staging allocation |
| M1-019 typed half-close | BLOCKED | Public pinned `TcpSocket` has no shutdown API; adapter reports `Unsupported` and requires UP-003 |
| M1-020 idempotent close/abort | COMPLETE | Native close is claimed once; close/cancel wake blocked read and listener accept without returning false EOF |
| M1-021 `StdNetTransportListener` | COMPLETE | IP-only bind, bounded backlog, endpoints and accept Deadline/cancel/close semantics |
| M1-022 stable std.net errors | BLOCKED | Timeout/cancel/closed are stable; public `SocketException` exposes no native code, so errno classes require an upstream API instead of message matching |
| M1-023 transport diagnostics | IN_PROGRESS | Backend/endpoints/capabilities and staging copied-byte counters exist; event sink/runtime backend discovery remain |

## Implemented Resolver and Connector Core

| Task | Status | Evidence |
|---|---|---|
| M2-001 host/IP/endpoint model | IN_PROGRESS | Strict canonical ASCII `HostName`, typed IPv4/IPv6/zone endpoints and equality/hash tests; IDNA and authority parsing remain |
| M2-002 Resolver contract | COMPLETE | All-address result, family filter, canonical host, source, optional expiration, structured errors and diagnostics |
| M2-003 bounded resolver backend | BLOCKED | M0-013 proves `std.net` DNS can starve carriers; the pinned SDK exposes neither async resolver nor an independent native worker API, so UP-007 is required |
| M2-005 Linux `SystemResolver` | BLOCKED | Depends on M2-003/UP-007; no direct `IPAddress.resolve` wrapper is presented as production-safe |
| M2-009 normalization/diagnostics | IN_PROGRESS | Stable deduplication preserves family/zone evidence and never invents TTL; trace event sink remains |
| M2-010 route model | NOT_STARTED | Direct/proxy and origin/proxy DNS separation remain |
| M2-011 RFC 8305 attempt plan | COMPLETE | Stable family interleaving, intra-family order, deduplication and bounded candidate tests |
| M2-012/013 Happy Eyeballs scheduler | COMPLETE | Shared parent Deadline, linked cancellation, atomic first winner, loser abort, joined candidates and per-attempt diagnostics |
| M2-014 scripted connector tests | IN_PROGRESS | IPv6 blackhole, simultaneous success, all-fail and pre-cancel cases pass; success+cancel/deadline boundary matrix remains |
| M2-015/016 native network gates/benchmark | NOT_STARTED | Linux network emulation, glibc/musl runs and DNS-to-connected benchmark remain |

## Implemented TLS Provider Foundation

| Task | Status | Evidence |
|---|---|---|
| M3-001 pinned static provider build | COMPLETE | AWS-LC 5.5.0 exact commit/tree, clean-source enforcement, fixed static options, single archive, native smoke and content-addressed build manifest |
| M3-002 provider SPI/build manifest | COMPLETE | Instance-owned opaque C ABI; provider-neutral Cangjie manifest exposes id/version/fingerprint/backend/capabilities/patch level; no native public type |
| M3-003 secure random adapter | COMPLETE | AWS-LC CSPRNG fills caller-owned buffers, maps stable structured failures, logs no bytes and passes lifecycle tests |
| M3-004 external byte-stream pump | COMPLETE | AWS-LC memory-BIO step/feed/drain ABI; bounded `TlsEnginePump` handles WANT_READ/WANT_WRITE, partial I/O, one absolute Deadline/cancel context, EOF and zero-progress fail-closed paths; native and Cangjie ClientHello smoke passes |
| M3-005 `TlsConnection` lifecycle | COMPLETE | Handshake consumes engine/transport on success and failure; AWS-LC plaintext read/write ABI; one reader plus one writer, same-direction exclusion, failure/timeout abort, idempotent close/abort and 100-way terminal-race loops prove exactly-once release |
| M3-006 immutable TLS contexts | COMPLETE | Builder-only mutable state; built client/server contexts defensively copy ALPN/configuration, expose immutable policy/capabilities and pass concurrent-sharing tests |
| M3-007 security profiles | COMPLETE | Compatible/Modern default to TLS 1.2..1.3, StrictTls13 pins 1.3; AWS-LC min/max protocol controls enforce the selected range and compression, renegotiation, NULL/anonymous suites and 0-RTT remain disabled without cipher-string configuration |
| M3-008 capability query/fail-fast | COMPLETE | Explicit systemTrust/customRoots/hardwareKeys/clientCertificate/serverMode/tls12/tls13/http2/networkBinding inventory; unsupported trust, key, version, HTTP/2 and server/mTLS requirements fail during context construction |
| M3-009 `TrustPolicy`/evidence model | COMPLETE | System/CustomRoots/SystemPlusCustomRoots/PinnedPublicKeys are immutable and content-identified with SHA-256; no TrustAll state exists; normalized verification evidence contains no native object |
| M3-010 bounded certificate input | COMPLETE | Exact DER X.509 decoding is performed by pinned AWS-LC; 16-chain/256-KiB-certificate/1-MiB-total/128-extension hard ceilings, duplicate rejection and bounded SAN extraction fail closed |
| M3-011 reference identity verifier | COMPLETE | SAN-only DNS/IP models, no CN field/fallback, ASCII IDNA A-label handling, one-label wildcard rules, 256-SAN ceiling and native SNI/reference separation tests |
| M3-012 custom roots/pinning | COMPLETE | CustomRoots and SystemPlusCustomRoots load explicit DER anchors without disabling identity verification; SPKI SHA-256 leaf/any-chain pins pass a real matching client/server memory-BIO handshake and reject a mismatched pin |
| M3-013 Linux system trust | IN_PROGRESS | Frozen ordered bundle/hashed-directory discovery, explicit AWS-LC loading, no provider-default fallback and current glibc host tests pass; native musl adapter execution evidence remains |
| M3-016 `LocalIdentity`/opaque key contract | COMPLETE | One immutable identity binds a certificate chain to PKCS#8, opaque system handle/alias, or external signer refs; signer algorithms and SPKI are bounded, leaf/key matching is native, hardware capability is explicit, and key material/native handles never enter the public contract |
| M3-017 PKCS#8/file identity | COMPLETE | Exact bounded unencrypted DER PKCS#8 and absolute readable regular-file adapters; native leaf/key match validation occurs during identity construction, transient copies are zeroed, close clears owned bytes, and server handshake uses the configured key |
| M3-018 external signer bridge | COMPLETE | AWS-LC `SSL_PRIVATE_KEY_METHOD` captures a bounded request and returns retry; the pump calls the signer with the operation context outside native callbacks and engine/provider locks, then completes or fails the pending operation; real handshake, user exception and pre-sign cancellation paths pass |
| M3-021 client handshake/result | COMPLETE | Successful production-engine handshakes expose immutable TLS version, IANA cipher name, negotiated ALPN, bounded DER peer chain, normalized verification evidence, resumption bit and provider manifest; `TlsConnection` snapshots the result before taking ownership, while failure/cancel/timeout still abort both inputs |
| M3-022 SNI context selection | COMPLETE | AWS-LC pauses certificate selection into instance-owned state; the pump performs exact canonical SNI lookup outside native callbacks and locks, installs the selected immutable context's protocol/identity/ALPN/mTLS policy, and fails closed for absent or unknown names; paired real handshakes prove certificate and policy selection |
| M3-023 ALPN/no-shared semantics | COMPLETE | Client offers and server preference lists use bounded RFC 7301 wire encoding; server preference wins deterministically, both endpoints report the same selected value, and either configured endpoint fails closed when no protocol is selected or shared |
| M3-024 mutual TLS | COMPLETE | Client identities are installed from immutable contexts; server None/Optional/Required modes configure AWS-LC verification explicitly; required succeeds with a verified client chain and rejects absence, while optional succeeds without inventing peer evidence |

## Next critical path

1. Complete shared Transport lifecycle/exactly-once primitives and the remaining
   deterministic race tests.
2. Submit the minimal `std.net` upstream interface RFC for typed half-close and
   stable native error evidence.
3. Land UP-007 or another proven non-carrier-blocking resolver backend, then
   complete Linux `SystemResolver` and native blackhole gates.
4. Complete native musl trust-adapter evidence, then session, close-notify and
   structured TLS error work under ADR-0003.
5. Implement HTTP/1.1, HTTP/2, Linux conformance, fuzz, benchmark, 24-hour soak,
   packaging and installation verification.
