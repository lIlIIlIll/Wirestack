# M7-028 evidence

## Status

COMPLETE

## Scope

M7-028 prepares the Linux x86_64 glibc independent security review package at
[`docs/security/review/linux-1.0/`](../../security/review/linux-1.0/README.md).
It digest-binds threat-model, architecture, provider and C ABI, parser, key and
trust, fuzz, SBOM, limitation, environment, and reproduction material.

The package does not claim that an independent review has occurred. Artifact,
installation, performance and supply-chain evidence regenerated after M7-032
is labelled current. The point-in-time M7-019 audit remains stale until the
final M7-031 candidate matrix supersedes it. M7-026 remains historical and
non-gating under the pre-1.0 compatibility policy.

## Acceptance evidence

- [`linux_x86_64/review-package.json`](linux_x86_64/review-package.json)
  records 11 review documents and 13 digest-bound evidence entries: 8 current
  PASS reports, 3 current inputs bound by the PASS supply-chain bundle, 1 stale
  point-in-time audit, and 1 historical non-gating entry.
- [`task-check.json`](task-check.json) records all three short task commands as
  PASS. The fault-injection suite passed 9/9 tests.
- [`evidence.json`](evidence.json) binds the reports and task source files for
  freshness verification.
- The package rejects path escapes, unknown schemas, missing files, digest
  drift, false PASS states, sensitive values in both review documents and
  evidence files, compatibility gating, and partial report replacement.

## Deliberately unrun gates

- one-hour SSE profile was not rerun during this evidence refresh;
- 86,400-second M7-022 release soak;
- non-Linux platform validation.
