# ADR-0003: Linux TLS provider selection

- Status: Accepted for the Linux delivery profile
- Date: 2026-08-24
- Related tasks: M0-016, M0-018, Linux profile of M0-020
- Amended by: ADR-0004

## Context

When this ADR was accepted, ADR-0002 permitted a Linux-only provider decision
after one candidate passed every required native capability on both Linux glibc
and Linux musl. ADR-0004 later removed musl from the current Wirestack release
matrix because the Cangjie SDK does not support that target. The provider
decision must still preserve the threat-model controls for supply chain,
private-key isolation, native callbacks and deterministic cleanup.

AWS-LC 5.5.0 at commit
`991e67ff4cf04df4dd89e407f8b920c6936cb56a` now has retained schema-v2 `PASS`
results on Linux glibc x86_64 and Linux musl x86_64. Both results prove:

- TLS 1.2 and TLS 1.3 client/server handshakes over caller-owned bounded BIOs;
- SNI, reference-identity verification, ALPN, custom CA, mTLS and session reuse;
- negative hostname and trust cases, clean `close_notify` and truncation;
- caller cancellation and partial-I/O/backpressure behavior;
- an external signing callback invoked by both TLS 1.2 and TLS 1.3 without
  installing the private key into the TLS context;
- 10,000 repeated handshake/close cycles; and
- static archives with no system TLS-library dependency or runtime-loader
  library string.

Mbed TLS remains incomplete for external signing and session resumption.
Vendored OpenSSL is the control and remains incomplete for external signing.

## Decision

The Linux delivery profile selects **AWS-LC 5.5.0**, pinned to commit
`991e67ff4cf04df4dd89e407f8b920c6936cb56a`, as its default TLS provider.

The following rules are mandatory:

1. Provider selection is a build-time decision. Linux artifacts must not probe,
   load or fall back to a system `libssl` or `libcrypto` at runtime.
2. AWS-LC is built from the pinned source with shared libraries disabled. The
   production build records every build option, patch and target toolchain.
3. Provider state is instance-owned. Production code must not copy the PoC's
   process-global signer fixture or expose AWS-LC handles through public APIs.
4. File-backed private keys and external signers implement one opaque
   `PrivateKeyRef` contract. External signer failures, retry and cancellation
   fail closed; user exceptions never cross the C ABI.
5. Trust policy is owned by Wirestack and the Linux trust adapter. No provider
   default silently replaces the selected system/custom trust policy.
6. A source-pin or patch change must rerun the complete Linux glibc PoC, static
   dependency scan, TLS tests, fuzz corpus and performance gates before
   promotion. The musl PoC becomes required only after P1-011 starts.

## Supply-chain and release policy

AWS-LC is consumed under `Apache-2.0 OR ISC`. Every Linux release SBOM and
provider manifest records at least:

- provider id and version;
- upstream commit and tree identity;
- repository-controlled patch identities;
- build flags, compiler, target triple and feature set;
- static archive and final artifact digests; and
- `externalOpenSslDependency: false`.

The Wirestack maintainers own advisory intake, source-pin updates and downstream
release publication. M7-015 defines the final severity SLA and operational
runbook; until then, a known affected pin blocks a release.

Rollback means publishing or restoring a previously reviewed pinned AWS-LC
build and rerunning its Linux gates. It never means enabling a system library or
switching providers at runtime. If no reviewed safe pin exists, the affected
artifact is withdrawn rather than silently downgraded.

## Consequences

- Linux TLS integration tasks M3-001 and later may begin against one frozen
  provider and C ABI boundary.
- AWS-LC-specific code remains internal to the native provider adapter.
- The global six-platform provider decision remains open. This ADR does not
  claim Windows, macOS, Android, iOS or HarmonyOS/OpenHarmony support.
- Real platform keystore/HSM adapters still require their own native evidence;
  the PoC proves the external signing boundary, not a particular device service.

## Evidence

- `docs/evidence/M0-016/results/linux-glibc-x86_64/aws-lc.json`
- `docs/evidence/M0-016/results/linux-musl-x86_64/aws-lc.json`
- `docs/evidence/M0-016/platform-matrix.json`
- `docs/security/threat-model.md`
- `docs/architecture/adr/0002-linux-first-delivery-profile.md`

## Follow-up tasks

- M3-001 pins and integrates the production static build.
- M3-002 defines the provider SPI and manifest.
- M3-003 through M3-024 implement and verify TLS Core and Linux adapters.
- M7-010, M7-011 and M7-015 close SBOM, artifact signing and security-update
  operations.
