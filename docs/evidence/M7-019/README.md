# M7-019 Linux requirement audit

Status: **COMPLETE**

Audit decision: **AUDIT_COMPLETE_RELEASE_BLOCKED**

This task completes the fail-closed traceability audit for the Linux x86_64
glibc delivery profile. It does not declare the Linux stable release ready.

## Scope and method

The machine-checked audit covers the complete inventory required by M7-019:

| Inventory | Total | PASS | GAP | NOT_APPLICABLE_TO_LINUX_PROFILE |
|---|---:|---:|---:|---:|
| P0 requirements | 32 | 31 | 1 | 0 |
| Lifecycle invariants | 15 | 15 | 0 | 0 |
| Release acceptance criteria | 22 | 15 | 6 | 1 |

The canonical record is
[`linux_x86_64/audit.data`](linux_x86_64/audit.data). Each Linux-applicable
entry links its implementation, test, or retained report. The validator binds
the inventory to the current PRD and backlog hashes, checks every evidence path,
and rejects removed requirements, weakened gaps, stale source hashes, or a
mobile-only criterion reported as Linux PASS.

Run the audit with:

```shell
scripts/validate-m7-019-linux-audit
```

## Blocking evidence gaps

| Requirement | Missing release evidence | Owning task |
|---|---|---|
| TLS-PROV-004 | Artifact-bound provider manifest and build fingerprint | M7-025 |
| REL-04 | Installed Linux release artifact and system OpenSSL dependency scan | M7-021 |
| REL-13 | Consolidated, versioned Linux release performance gate | M7-024 |
| REL-14 | Continuous fuzz thresholds and crash replay gate | M7-023 |
| REL-15 | Independent security review with no open High/Critical finding | M7-029 |
| REL-16 | Artifact-bound SBOM and provider manifest | M7-025 |
| REL-19 | Final installed-artifact 24-hour mixed resource soak | M7-022 |

REL-03 covers Android and iOS foreground listeners only. It is
`NOT_APPLICABLE_TO_LINUX_PROFILE`, not PASS.

## Upstream independence

No blocker in this audit requires changing the Cangjie runtime or `std.net`.
Wirestack closes the Linux profile with public SDK APIs, bounded internal
implementations, and stable capability fallbacks. UP-001 through UP-007 remain
optional, long-term upstream requirements; they are not build, test, readiness,
completion, or release dependencies for Wirestack.

In particular, missing typed half-close and native socket error details are
represented by stable public capability and error behavior. DNS carrier-thread
pressure is handled by Wirestack's bounded resolver backend. This repository
does not modify or build runtime/std as part of M7-019.

Linux musl is outside this profile because the supplied Cangjie SDK does not
support it. This audit neither passes nor fails musl.

## Evidence boundary

This audit proves that the requirement inventory is complete and identifies
all current Linux evidence gaps. It does not:

- complete global M7 or any non-Linux platform cell;
- substitute component binaries for the final installed release artifact;
- substitute deterministic mutation tests for the release fuzz threshold;
- substitute internal review for an independent security review;
- claim the Linux stable release is ready before M7-020 through M7-031 close.
