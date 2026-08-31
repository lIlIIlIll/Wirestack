# M0-016 TLS provider PoC contract

M0-016 compares the three candidates frozen by M0-015 without selecting the final provider. Every result is tied to an exact source identity, native platform, static build and capability register.

## Candidates

- `aws-lc`: primary candidate, pinned by exact Git commit.
- `mbedtls`: secondary candidate, pinned by the official release archive SHA-256 and release commit.
- `openssl`: vendored control, pinned by the official release archive SHA-256; the run resolves the annotated release tag to its exact commit.

Version changes require a reviewed change to `tools/tls_provider_poc/providers.json`; a floating branch, unverified archive or package-manager “latest” is rejected.

## Native result states

- `PASS`: every required capability passed and the executable has no system TLS-library dependency.
- `PARTIAL`: build and executed capabilities passed, but at least one required capability is explicitly `BLOCKED`.
- `FAIL`: build, source integrity, static-link boundary or an executed capability failed.
- `BLOCKED`: the native platform or required environment is unavailable.

`NOT_RUN`, missing cells and cross-compilation never count as native evidence.
Schema versions 1 through 6 are no longer accepted because they cannot carry
the complete callback, protocol-negative, certificate-negative, export,
execution, durable build-provenance, license, provider-allocation,
provider-instrumentation, bounded join, live-allocation-growth and cancellation
evidence. Schema v7 is required for retained `PASS` and `PARTIAL` results. It requires an
exact, bounded inventory of the final artifact's exported symbols and exactly
10,000 measured cleanup
cycles. When session resumption passes, the result must record four measured
handshakes: a fresh and resumed TLS 1.2 handshake, plus a fresh and resumed TLS
1.3 handshake after ticket delivery. A provider cannot infer resumption from a
successful fresh handshake.

Every successful native result records the exact repository revision and
hosted-runner image identity. A musl result additionally records the immutable
container name and digest; a mutable tag or artifact-level association is not
sufficient. The result retains normalized configure/build argv, compiler,
C++ compiler, CMake when used, build-tool version output, target triple, and an
allowlisted snapshot of the effective build environment. The snapshot includes
inherited compiler, CMake, SDK, search-path and MSVC DevShell variables as well
as runner-supplied overrides; absent allowlisted variables are recorded as
empty values. Each value and the complete snapshot are bounded. Temporary build
paths are replaced by stable markers. The result also retains an explicit
digest-bound patch set; a build-log digest alone is not durable provenance.
Provider license files are copied from the pinned source into a
bounded bundle. Its manifest binds the provider, source digest, relative file
paths, byte counts, and file digests, and the result binds the manifest digest.
The canonical matrix also references a committed copy of that exact manifest;
matrix validation reads and hashes every referenced license file.

An mTLS `PASS` records one required-client-auth handshake and two optional
client-auth handshakes: one without a client certificate and one with a valid
client certificate. A required-only result is incomplete.

Every successful result records a process peak-resident measurement bounded by
512 MiB. Provider allocation hooks separately record cumulative provider
allocation calls and bytes plus peak live provider bytes across the complete
profile. The profile records live bytes before and after the 10,000 cleanup
cycles and rejects any increase; fixed harness payload buffers do not satisfy
this field. Linux glibc
and macOS also require a passing ASan and UBSan diagnostic run built from newly
instrumented provider archives, not an instrumented harness linked to ordinary
Release archives. Platforms where that configured diagnostic is unavailable
must record `UNSUPPORTED`; they may not report a skipped diagnostic as `PASS`.

Leak detection is a separate field. Linux glibc Mbed TLS requires
LeakSanitizer `PASS`. AWS-LC 5.5.0 exposes no process-global cleanup API, and
static OpenSSL 3.6.3 retains process-global allocations even after explicit
thread and global cleanup. Broad allocator suppression would also hide real
provider leaks, so AWS-LC, OpenSSL, and the configured macOS runs record leak
detection as `UNSUPPORTED`. The ASan/UBSan run and 10,000-cycle
resident/allocation profile remain mandatory.

A caller-cancellation `PASS` starts the provider handshake step on a worker,
observes a native WANT state, blocks the caller-owned wait, sends an explicit
cancel signal, and measures the wake and join against a 250,000-microsecond
bound. Merely freeing a WANT-state connection is not cancellation evidence.
The join is part of the same absolute bound and may not use an infinite wait.

Each provider pin records its upstream commit timestamp, a maximum acceptable
age and official advisory intake URLs. `validate.py` fails closed when a pin is
too old. A known affected pin blocks promotion even when it is within the age
limit; `docs/security/provider-update-workflow.md` defines the review cadence
and rerun boundary.

An external-trust `PASS` requires at least four callback invocations. The PoC
must accept and reject an otherwise-untrusted valid chain through the callback
for both TLS 1.2 and TLS 1.3. Installing the same CA in the provider before the
accept callback runs does not prove external trust. An AWS-LC external-signer
`PASS` requires at least two observed callback invocations so TLS 1.2 and TLS
1.3 are both exercised.

## Required capability surface

The PoC exercises TLS 1.2/1.3, SNI/reference identity/ALPN, caller-supplied CA,
mTLS, dual-version session resumption, negative certificate cases,
caller-driven partial I/O and backpressure, bounded cancellation, clean
`close_notify`, truncation classification and repeated cleanup.
External/non-exportable signing must be executed or remain explicitly
`BLOCKED`; it may not be inferred from a header or marketing claim.
An ALPN `PASS` requires successful negotiation plus no-overlap rejection in TLS
1.2 and TLS 1.3. It also requires rejection of zero-length and overlong protocol
identifiers before a handshake starts.

The certificate-negative register has separate expired and malformed
capabilities. An expired certificate must reach native chain verification and
fail with the provider's expiry classification. A malformed certificate must
be rejected while loading provider material, before any handshake starts. A
result that passes both cases records exactly two rejected certificate-negative
cases.

OpenSSL-compatible candidates use a bounded BIO pair so the caller owns transport progress. Mbed TLS uses caller-provided send/receive callbacks backed by bounded ring buffers. The PoCs never open a socket.

## Static dependency boundary

Each provider is built from vendored source with shared libraries disabled. The final PoC binary is linked to the resulting archives. The run retains archive SHA-256 values, inspects the executable with the native dependency tool (`ldd`, `otool` or `dumpbin /dependents`) and records the sorted, bounded final-artifact export inventory from `nm` or `dumpbin /exports`. A dependency or runtime-library string for system `libssl`, `libcrypto` or Mbed TLS libraries is a failure.

The host `openssl` command is allowed only to create ephemeral test certificates. It is not used by the PoC data path and does not satisfy any provider capability.

## Platform matrix

The canonical matrix covers Linux glibc/musl, Windows, macOS, Android, iOS and HarmonyOS/OpenHarmony for every candidate. Hosted or device evidence is committed only after execution. Absent mobile devices remain `BLOCKED`; a successful cross-build can be retained as supplementary evidence but cannot replace a native run.

## Selection boundary

M0-016 records evidence and blockers. M0-020 owns the provider decision and must consume the full matrix, license review, threat model and residual failures. M0-016 must not silently turn a partial Linux result into a six-platform recommendation.
