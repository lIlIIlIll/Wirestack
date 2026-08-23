# Wirestack P0 Threat Model

**Task:** M0-018  
**Review date:** 2026-08-23  
**Status:** versioned baseline; every HIGH/CRITICAL item remains a stable-release blocker until its mapped implementation and verification tasks close it.

This model governs the Wirestack Transport, TLS, HTTPS, HTTP/1.1 and HTTP/2 design described by the PRD. It is fail-closed: unavailable platforms, skipped tests, unresolved provider behavior, cross-compilation-only results and missing evidence never reduce risk.

## Scope and non-goals

In scope are the provider/build supply chain, public API and internal package boundaries, `std.net` adapter, DNS/connector/proxy path, TLS trust/key/session semantics, HTTP parsers and state machines, resource bounds, observability, native callbacks, platform adapters, CI and release evidence.

This document does not select the final TLS provider, replace the M0-016 native PoC, approve a public API, or mark a platform supported. M0-020 selects the provider only after M0-016 and this threat model are reviewed.

## Security objectives

- Authenticate the intended peer by validating both certificate chain and reference identity; SNI, DNS name, IP literal, trust roots and pinning remain distinct inputs.
- Preserve confidentiality and integrity of plaintext, credentials, private keys, session state and provider secrets across API, FFI, logging and crash paths.
- Preserve unambiguous protocol, message and terminal semantics; reject smuggling, malformed frames, downgrade, truncation and local-close/peer-EOF confusion.
- Bound CPU, memory, queues, buffers, tables, windows, pools, tasks, timers and native resources under adversarial input.
- Ensure cancellation, Deadline, close and abort complete at most once and clean every waiter, timer, registration and native allocation.
- Make every platform and release claim traceable to exact source pins, native execution, tests, SBOM and signed artifacts.

## Attackers

- An active or passive network attacker able to intercept, delay, reorder, truncate, replay or inject DNS, TCP, proxy, TLS and HTTP traffic.
- A malicious or compromised peer sending adversarial certificates, handshakes, HTTP/1.1 bytes, HTTP/2 frames or flow-control patterns.
- A malicious proxy or local network configuration changing routing, authentication, DNS answers or connection identity.
- A compromised upstream dependency, source archive, build tool, CI runner, signing credential or artifact mirror.
- An untrusted application caller or callback supplying malformed configuration, throwing/re-entering unexpectedly, or trying to exfiltrate secrets through diagnostics.
- A local observer with access to logs, traces, crash dumps, environment variables or process metadata, but not arbitrary kernel compromise.

## Assumptions

- OS kernels, selected cryptographic primitives and authenticated system trust/key APIs are outside Wirestack implementation scope but not outside verification.
- The Cangjie runtime and `std.net` public contract are trusted only to the extent demonstrated by M0 gates; private `CJ_MRT_Sock*` ABI is never used.
- Applications may opt into weaker policy only where the public API makes the downgrade explicit; defaults remain fail-closed.
- Cross-compilation and source portability are build evidence, not native platform evidence.
- Denial of service cannot be eliminated on a finite host; Wirestack must enforce explicit bounds and deterministic cleanup.

## Protected assets

| ID | Asset |
|---|---|
| `A-ARTIFACT` | Provider, Wirestack and final release artifact integrity and provenance |
| `A-KEY` | Client/server private keys, opaque handles and signing authority |
| `A-SESSION` | TLS sessions, tickets, resumption state and related secret material |
| `A-PLAINTEXT` | Application plaintext, HTTP bodies and decrypted traffic |
| `A-CREDENTIAL` | Authorization, cookies, proxy credentials and client identity |
| `A-PEER_IDENTITY` | Certificate chain, reference identity, SNI, DNS/IP and pinning decisions |
| `A-HTTP` | HTTP/1.1 and HTTP/2 message boundaries, semantics and state |
| `A-POOL` | Connection-pool identity, reuse eligibility and route isolation |
| `A-TERMINAL` | EOF, RST, close, abort, cancel, deadline and truncation evidence |
| `A-RUNTIME` | Cangjie runtime, scheduler, FFI callbacks and native memory safety |
| `A-AVAILABILITY` | CPU, memory, tasks, connections, handles and network availability |
| `A-EVIDENCE` | Tests, benchmarks, fuzzing, SBOM, signatures and platform evidence |

## Trust boundaries

```text
Application
    │ public API
    ▼
HTTP Core ──► TLS Core ──► Transport SPI ◄── StdNetTransport ──► std.net/runtime/OS
    │             │              │
    │             └──► TLS provider / native callbacks
    └──► proxy / DNS / pool / observability / evidence and release pipeline
```

The canonical register names the boundaries `B-API`, `B-TRANSPORT`, `B-PEER`, `B-PROXY`, `B-DNS`, `B-PROVIDER`, `B-CALLBACK`, `B-OS`, `B-RUNTIME`, `B-H1`, `B-H2`, `B-POOL`, `B-OBS`, `B-BUILD`, `B-CI` and `B-EVIDENCE`.

## Severity and disposition

| Severity | Meaning | Release treatment |
|---|---|---|
| CRITICAL | Broad compromise of authentication, keys, plaintext, artifact integrity or systemic memory safety | `release_blocker=true`; never `ACCEPTED` before independent M7 review |
| HIGH | Practical security bypass, identity confusion, smuggling, unbounded resource attack or terminal corruption | `release_blocker=true`; never `ACCEPTED` before stable release |
| MEDIUM | Limited impact requiring constrained preconditions | Explicit mitigation, verification and owner required |
| LOW | Defense-in-depth or low-impact issue | Acceptance requires documented rationale |

Statuses are `OPEN`, `MITIGATED_BY_DESIGN`, `DEFERRED` and `ACCEPTED`. A design mitigation is not verified until the mapped task evidence exists.

## Threat register

| ID | Domain | Severity | Status | Attack scenario | Controls | Verification tasks |
|---|---|---:|---|---|---|---|
| `T-SUPPLY-001` | supply_chain | CRITICAL | OPEN | Compromised provider source, dependency or patch enters all artifacts | `C-SUPPLY`, `C-EVID` | `M0-016`, `M0-020`, `M3-001`, `M7-010`, `M7-015` |
| `T-SUPPLY-002` | supply_chain | CRITICAL | MITIGATED_BY_DESIGN | Runtime loader selects hostile or stale system TLS libraries/modules | `C-SUPPLY`, `C-EVID` | `M0-003`, `M0-016`, `M0-020`, `M7-003` |
| `T-TRUST-001` | certificate_identity | CRITICAL | OPEN | Invalid, expired, malformed or untrusted certificate chain is accepted | `C-TRUST`, `C-PLAT` | `M3-009`, `M3-010`, `M3-012`, `M3-013`, `M4-003` |
| `T-TRUST-002` | certificate_identity | CRITICAL | OPEN | DNS/IP/SNI/reference-identity confusion authenticates the wrong peer | `C-TRUST` | `M2-001`, `M3-010`, `M3-011`, `M7-006` |
| `T-KEY-001` | key_boundary | CRITICAL | OPEN | Private key, signer authority, entropy or provider handles escape the opaque boundary | `C-KEY`, `C-ABI`, `C-OBS` | `M3-003`, `M3-016`, `M3-017`, `M3-018`, `M4-005` |
| `T-TLS-001` | tls_protocol | HIGH | MITIGATED_BY_DESIGN | Provider defaults enable downgrade, obsolete protocol or insecure features | `C-TLS`, `C-EVID` | `M3-006`, `M3-007`, `M3-008`, `M3-024` |
| `T-CLOSE-001` | transport_lifecycle | HIGH | OPEN | Truncation, local close or cancellation is reported as graceful close/EOF | `C-LIFE` | `M0-009`, `M0-019`, `M1-017`, `M1-020`, `M3-020` |
| `T-RACE-001` | cancellation_race | CRITICAL | OPEN | Success, timeout, cancel, close and abort cause double completion, UAF or leaks | `C-LIFE`, `C-ABI` | `M1-004`, `M1-005`, `M1-008`, `M1-024`, `M3-027` |
| `T-DNS-001` | dns_route | HIGH | OPEN | Slow DNS blocks carrier threads or grows an unbounded resolver queue/pool | `C-DNS`, `C-BOUND` | `M0-013`, `M2-002`, `M2-003`, `M2-004`, `M2-007` |
| `T-ROUTE-001` | dns_route | HIGH | OPEN | Origin/proxy DNS or network-binding confusion routes credentials incorrectly | `C-DNS`, `C-POOL` | `M2-001`, `M2-009`, `M2-010`, `M2-013`, `M5-021`, `M5-022` |
| `T-H1-001` | parser_smuggling | CRITICAL | OPEN | CL/TE, whitespace, obs-fold, CRLF or chunk ambiguity enables smuggling | `C-H1`, `C-BOUND` | `M5-002`, `M5-003`, `M5-007`, `M5-012`, `M5-015`, `M5-029` |
| `T-H2-001` | parser_smuggling | HIGH | OPEN | Malformed frame order, continuation, settings, pseudo-header or HPACK state corrupts streams | `C-H2`, `C-BOUND` | `M6-002`, `M6-003`, `M6-006`, `M6-008`, `M6-011`, `M6-019` |
| `T-RESOURCE-001` | resource_exhaustion | HIGH | OPEN | Chains, headers, frames, streams or slow bodies grow resources without limit | `C-BOUND`, `C-H1`, `C-H2` | `M3-010`, `M5-003`, `M5-006`, `M5-018`, `M6-006`, `M7-005` |
| `T-POOL-001` | connection_pool | CRITICAL | OPEN | Incomplete pool/session key reuses an authenticated channel across contexts | `C-POOL`, `C-TRUST`, `C-KEY` | `M3-012`, `M3-016`, `M3-024`, `M5-017`, `M6-018` |
| `T-OBS-001` | logging_secrets | CRITICAL | OPEN | Logs, traces, crashes or key logging disclose secrets, credentials or bodies | `C-OBS`, `C-EVID` | `M1-006`, `M3-003`, `M3-025`, `M5-028`, `M7-012` |
| `T-ABI-001` | c_abi | CRITICAL | OPEN | Length, allocator, reentrancy or exception errors corrupt native memory | `C-ABI`, `C-LIFE`, `C-BOUND` | `M3-002`, `M3-004`, `M3-016`, `M3-027`, `M3-028`, `M7-008` |
| `T-PLAT-001` | platform_adapter | HIGH | OPEN | Platform adapters diverge or cross-compilation is mislabeled native support | `C-PLAT`, `C-EVID` | `M0-016`, `M0-017`, `M3-013`, `M3-014`, `M4-014` |
| `T-EVID-001` | release_integrity | HIGH | MITIGATED_BY_DESIGN | Stale, skipped, simulated or cross-compiled evidence authorizes a release | `C-EVID`, `C-SUPPLY` | `M0-004`, `M0-017`, `M0-022`, `M7-004`, `M7-010`, `M7-017` |

## Residual risks

- Pinned provider and dependency source may still contain undiscovered vulnerabilities; each artifact needs dependency, symbol and advisory scans.
- Platform trust, route and key-store policy can change after release and must remain visible in native evidence.
- Native provider code cannot be proven memory-safe by tests alone; sanitizers, fuzzing, negative callbacks and repeated lifecycle races remain required.
- Parser and identity corpora require maintenance as intermediaries, Unicode/IDNA behavior and protocol attacks evolve.
- Small-device resource limits require native calibration; the PRD limits are mandatory ceilings, not permission for unbounded defaults.
- Application callbacks may log their own secrets, and OS/CI/device compromise cannot be fully prevented by Wirestack.

The machine-readable register records a residual-risk statement for every threat.

## Control catalogue

| Control | Mandatory rule | Implementation / verification tasks |
|---|---|---|
| `C-SUPPLY` | Pin provider/dependencies/patches/licenses; build-time provider only; no system TLS fallback; signed SBOM/artifacts | `M0-016`, `M0-020`, `M3-001`, `M7-003`, `M7-010`, `M7-011`, `M7-015` |
| `C-TRUST` | Validate chain and reference identity by default; keep SNI/DNS/IP/trust distinct; no public TrustAll | `M3-009`–`M3-012`, `M3-023`, `M7-006` |
| `C-KEY` | Keep private keys opaque; signer/RNG failures fail closed; no secret/provider handle escapes | `M3-003`, `M3-016`–`M3-019`, `M4-005`, `M4-009`, `M4-013` |
| `C-TLS` | Immutable contexts disable insecure features and reject unsupported capability before networking | `M3-006`–`M3-008`, `M3-021`, `M3-024` |
| `C-LIFE` | One monotonic operation context; typed terminal states; exactly-once completion and cleanup | `M0-006`–`M0-009`, `M0-019`, `M1-003`–`M1-005`, `M1-008`, `M1-024`, `M3-020` |
| `C-DNS` | Bound resolver/attempt queues and separate origin/proxy DNS, route and network binding | `M0-013`, `M2-002`, `M2-003`, `M2-009`, `M2-010`, `M2-012`, `M2-013` |
| `C-H1` | Strict shared HTTP/1 framing; reject CL/TE ambiguity, obs-fold, CRLF and invalid chunks | `M5-002`, `M5-003`, `M5-007`, `M5-009`, `M5-010`, `M5-012`, `M5-015`, `M5-029` |
| `C-H2` | Validate frame/state order and bound HPACK, continuation, windows, streams and writes | `M6-002`–`M6-006`, `M6-008`, `M6-010`, `M6-011`, `M6-019` |
| `C-BOUND` | Give certificate, record, header, frame, buffer, queue, pool, session, stream, timer and drain resources hard limits | `M1-018`, `M3-010`, `M3-015`, `M5-003`, `M5-004`, `M5-006`, `M5-018`, `M5-019`, `M6-006`, `M6-010`, `M7-005` |
| `C-POOL` | Include origin, proxy, network, TLS context, trust, identity, provider and ALPN in reuse keys | `M3-012`, `M3-016`, `M3-024`, `M5-017`, `M5-018`, `M6-018` |
| `C-OBS` | Exclude keys, session/traffic secrets, credentials and bodies from default logs; disable release key logging | `M1-006`, `M3-003`, `M3-025`, `M5-022`, `M5-028`, `M7-001`, `M7-012` |
| `C-ABI` | Validate callback lengths/ownership, translate exceptions, and avoid user callback under provider-global locks | `M0-018`, `M3-002`, `M3-004`, `M3-016`, `M3-027`, `M3-028`, `M7-008` |
| `C-PLAT` | Require native trust/key/network evidence and fail closed when a capability is unavailable | `M0-016`, `M0-017`, `M3-008`, `M3-013`, `M3-014`, `M4-003`, `M4-007`, `M4-011`, `M4-014` |
| `C-EVID` | Bind evidence to commit, toolchain, target, native runner and artifact digests; skipped/stale/cross-compile cannot PASS | `M0-004`, `M0-017`, `M0-022`, `M4-014`, `M7-004`, `M7-010`, `M7-011`, `M7-017` |

## Architectural security invariants

- Only `wirestack.internal.transport_stdnet` may import `std.net`; public API and Core expose neither `std.net` nor provider-native types.
- Dependency direction remains `HTTP → TLS → Transport SPI ← StdNetTransport → std.net`.
- No direct private socket ABI, private socket handle, independent event loop, runtime provider guessing or automatic TLS-provider fallback.
- One monotonic absolute Deadline and one CancellationToken span DNS, connect, proxy, TLS, headers and body; no second timeout owner.
- EOF, graceful TLS close, peer truncation, RST, local close, abort, cancellation and deadline remain distinct wherever evidence exists.
- Every operation completes at most once; close/abort are idempotent; waiters, timers, registrations and native allocations are bounded and cleaned.
- All queues, buffers, pools, caches, HPACK tables, windows, chains, sessions and parser limits are explicit and tested.
- Default artifacts do not discover system OpenSSL and include source pins, notices, SBOM, dependency scan and signature.
- Secrets, headers, bodies, keys, tickets and credentials are redacted by default; TLS key logging is explicit and release-disabled.
- Platform support requires native device/VM evidence; cross-compilation, skipped execution or stale evidence cannot PASS.

## Review and release policy

HIGH/CRITICAL threats may not be ACCEPTED before M7 independent review; unresolved blockers or missing native platforms block stable release.

Review is required when the TLS provider or source pin changes, the Transport SPI or public API changes, a parser/state-machine limit changes, a platform adapter is added, a dependency advisory appears, or a release gate discovers new lifecycle/resource behavior. New threats require an ID, control mapping, real backlog tasks and residual-risk statement before merge.

## Verification

```bash
python3 tools/validate_threat_model.py
python3 -m unittest discover -s tools/tests -p 'test_validate_threat_model.py' -v
python3 -m py_compile tools/validate_threat_model.py
python3 tools/architecture_guard.py --root . --format text
```

The canonical register is [`threat-model.json`](threat-model.json). Its validator checks domain coverage, identifiers, cross-references, real backlog task IDs, required controls and the stable-release blocker rule.
