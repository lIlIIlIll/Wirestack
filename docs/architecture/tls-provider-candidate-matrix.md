# TLS provider candidate matrix

**Task:** M0-015  
**Review date:** 2026-08-23  
**Decision type:** candidate screening, not final provider selection

The canonical machine-readable matrix is
[`tls-provider-candidates.json`](tls-provider-candidates.json). This document
explains the disposition and defines the M0-016 proof obligations.

## Non-negotiable requirements

A default Wirestack provider must satisfy all of the following after native PoC:

1. permissive distribution terms compatible with Wirestack release artifacts;
2. TLS 1.2 and TLS 1.3 client and server support;
3. caller-owned transport I/O through callbacks, BIOs, or an equivalent explicit
   state machine;
4. ALPN, SNI, mTLS, hostname verification inputs and session resumption;
5. vendored/static builds that do not discover a system TLS library at runtime;
6. maintained security response and an auditable source pin;
7. feasible native delivery on Linux, Windows, macOS, Android, iOS and
   HarmonyOS/OpenHarmony;
8. provider-native types remain behind `wirestack.internal.tls_engine`.

A portable source tree or successful cross-compile is not platform evidence.
HarmonyOS/OpenHarmony remains `UNKNOWN` or `POC_REQUIRED` for every external
candidate until a native environment runs the probe.

## Disposition

| Candidate | Disposition | Main reason |
|---|---|---|
| AWS-LC | **Primary M0-016 PoC** | complete modern TLS surface, permissive licensing, active maintenance, suitable BIO/state-machine boundary |
| Mbed TLS | **Secondary M0-016 PoC** | portable C and explicit custom I/O callbacks; useful independent implementation comparison |
| OpenSSL 3.x, vendored | **Control PoC** | mature interoperability baseline; retained as a control, not selected by legacy familiarity |
| BoringSSL | Reference only | excellent technical reference, but upstream explicitly offers no stable API/ABI contract for general consumers |
| rustls-ffi | Conditional hold | memory-safe core, but Rust toolchain, mobile packaging, allocator/panic boundary and Harmony target need a separate cost case |
| wolfSSL | Excluded from default | GPL/commercial licensing is incompatible with the intended default permissive distribution model |
| s2n-tls | Excluded from default | upstream platform focus does not cover the six-platform P0 release matrix |
| platform-native TLS family | Excluded as one default | no single Linux-to-mobile engine contract; transport ownership and semantics diverge by platform |
| BearSSL | Excluded | TLS 1.3 is absent and maintenance/security-response suitability is uncertain |

No final provider has been selected. M0-020 owns the final ADR after M0-016
runtime evidence and M0-018 threat-model analysis.

## Why AWS-LC is the primary PoC

AWS-LC is the most direct candidate for testing the desired engine boundary:
OpenSSL/BoringSSL-style SSL state and BIO integration, TLS 1.2/1.3, client and
server operation, ALPN/SNI, certificate authentication and resumption. It is
actively maintained and can be pinned and built as repository-controlled source.

The PoC must still disprove the major risks:

- no hidden runtime dependency on system OpenSSL or provider modules;
- successful iOS and Harmony native packaging;
- stable custom-I/O behavior under partial read/write, cancellation and close;
- acceptable binary size, build time and symbol surface;
- a documented source-update and security-patch process.

## Why Mbed TLS remains in the shortlist

Mbed TLS provides a materially different implementation and build profile. Its
caller-provided I/O callback model is a good fit for a transport-independent TLS
engine, and its portable C design is attractive for mobile targets. The PoC must
verify TLS 1.3 interoperability, session behavior, certificate-path edge cases,
performance and system trust/non-exportable key adapter feasibility. Portability
is not treated as proof that Android, iOS or Harmony native delivery works.

## Why OpenSSL is only the control

A repository-pinned, vendored OpenSSL 3.x build can meet the no-system-library
rule and provides the strongest interoperability control. It is not the default
by assumption because the existing stdx design already demonstrated the costs of
runtime discovery, broad configuration surface and platform packaging. The PoC
must use a fixed static build with dynamic provider/module discovery disabled or
fully accounted for.

## M0-016 PoC contract

M0-016 must test AWS-LC and Mbed TLS. OpenSSL 3.x supplies a control result on at
least Linux, Windows and macOS; mobile control builds may be stopped when they no
longer add decision information, but that limitation must be explicit.

Each candidate run must retain:

### Build and artifact evidence

- exact upstream commit, recursive dependency digests and license bundle;
- compiler, CMake/build-system and target triple;
- static archive/shared-object dependency scan;
- final artifact size and exported-symbol inventory;
- proof that the default executable does not load system `libssl`/`libcrypto`;
- reproducible build command and patch set.

### Functional evidence

- TLS 1.2 and TLS 1.3 client/server handshakes;
- SNI and hostname-verification inputs;
- ALPN success, no-overlap and malformed inputs;
- system trust adapter boundary and custom CA bundle;
- server authentication, optional and required client authentication;
- session ID/ticket resumption with hit/miss evidence;
- partial read/write and transport backpressure through the provider adapter;
- graceful `close_notify`, peer truncation, local close and cancellation;
- deterministic negative cases for expired, wrong-host, untrusted and malformed
  certificates.

### Platform evidence

Native runs are required for:

```text
Linux glibc x86_64
Linux musl x86_64 or aarch64
Windows x86_64
macOS arm64 and/or x86_64 as supported by the runner matrix
Android arm64 device
 iOS arm64 device
HarmonyOS/OpenHarmony arm64 native environment
```

Cross-compilation is useful build evidence but cannot change a platform cell to
PASS.

### Operational evidence

- sanitizer or equivalent native memory diagnostics where supported;
- bounded handshake/read/write memory and allocation profile;
- cancellation/Deadline wakeup behavior;
- 10,000 repeated handshake/close cycles for the PoC stage;
- security-update workflow and maximum acceptable source-pin age;
- known CVE/advisory intake channels.

## M0-016 decision output

M0-016 does not merely report “build succeeded.” It must produce a comparable
result for each candidate:

```text
PASS
FAIL
BLOCKED
NOT_RUN
```

Any missing required platform, hidden system dependency, incompatible license,
uncancellable provider call, or inability to separate truncation from graceful
TLS closure blocks final selection. M0-020 may select a provider only from the
PoC results and may retain a second provider solely when the maintenance and
semantic cost is explicitly justified.

## Evidence sources

All source links in the JSON matrix point to upstream project or platform-owner
material. The review intentionally excludes third-party feature comparison
blogs as decision evidence. Exact source commits are frozen when M0-016 creates
its checkouts; M0-015 evaluates the candidate families and does not claim that
moving `main`/`HEAD` references are immutable evidence.
