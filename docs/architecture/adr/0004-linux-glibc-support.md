# ADR-0004: Current Linux libc support

- Status: Accepted
- Date: 2026-08-27
- Owner: Wirestack project owner
- Related task: M0-023
- PRD references: §0.1, §21.5

## Context

ADR-0002 required native Wirestack evidence on Linux glibc and Linux musl. The
current Cangjie SDK provides `x86_64-unknown-linux-gnu`. It does not provide a
supported musl target, matching standard library, or runtime. Both available
compilers reject `x86_64-unknown-linux-musl` with `The environment "musl" is not
found or supported!`.

The AWS-LC Alpine PoC proves that the C/C++ provider can run on musl. It cannot
compile or execute Wirestack Cangjie packages, so it is not Wirestack platform
evidence.

## Decision

The current Linux delivery and release target is native glibc x86_64. Linux
musl is unsupported by the current toolchain and is outside the current release
matrix.

Wirestack does not publish a musl artifact or claim musl compatibility from a
C/C++ PoC, a container, or a glibc binary. P1-011 owns future musl adoption. It
can start only after the Cangjie SDK publishes a supported musl target, standard
library, runtime, and build instructions.

M2-005, M2-015, M2-016, and M3-013 use native glibc evidence for the current
Linux profile. Existing musl probe failures remain in the repository as the
reason for deferral.

## Alternatives considered

### Keep musl as a current release requirement

Rejected. No supported toolchain can compile or execute the required Cangjie
packages, so the requirement cannot produce valid acceptance evidence.

### Treat provider-only musl execution as product support

Rejected. The provider PoC does not exercise Wirestack packages, public APIs,
resource ownership, cancellation, or runtime integration.

## Consequences

- The current Linux CI and release gates require native glibc execution.
- M2-005 and M3-013 can complete from their retained glibc evidence.
- M2-015 and M2-016 can proceed with the glibc profile.
- The global release matrix contains six current platforms. Linux means glibc.
- P1-011 must add native musl compile, unit, integration, dependency, benchmark,
  and installation evidence before Wirestack claims musl support.

## Evidence

- `docs/references/cangjie-linux-musl-target-availability-2026-08-27.md`
- `docs/evidence/M3-013/linux-musl-x86_64/toolchain-probe.data`
- `docs/evidence/M2-005/linux_glibc_x86_64/report.json`

## Follow-up tasks

- Complete M2-015 and M2-016 on native Linux glibc.
- Start P1-011 only after the Cangjie SDK supports Linux musl.
