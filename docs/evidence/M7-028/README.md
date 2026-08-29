# M7-028 evidence

## Status

COMPLETE

## Scope

M7-028 prepares the Linux x86_64 glibc independent security review package at
[`docs/security/review/linux-1.0/`](../../security/review/linux-1.0/README.md).
It digest-binds threat-model, architecture, provider and C ABI, parser, key and
trust, fuzz, SBOM, limitation, environment, and reproduction material.

The package does not claim that an independent review has occurred. Evidence
invalidated by M7-032 remains labelled stale. M7-026 remains historical and
non-gating under the pre-1.0 compatibility policy.

## Acceptance evidence

- [`linux_x86_64/review-package.json`](linux_x86_64/review-package.json)
  records 11 review documents and 12 digest-bound evidence entries: 4 current
  PASS, 7 stale after M7-032, and 1 historical non-gating entry.
- [`task-check.json`](task-check.json) records all three short task commands as
  PASS. The fault-injection suite passed 8/8 tests.
- [`evidence.json`](evidence.json) binds the reports and task source files for
  freshness verification.
- The package rejects path escapes, unknown schemas, missing files, digest
  drift, false PASS states, sensitive values, compatibility gating, and partial
  report replacement.

## Deliberately unrun gates

- final artifact rebuild and installation qualification;
- refreshed performance and SBOM qualification;
- one-hour SSE profile;
- 86,400-second M7-022 release soak;
- non-Linux platform validation.
