# M7-031 Linux release candidate

Status: **COMPLETE**

M7-031 issues a `GO_FOR_LINUX_STABLE_RELEASE` decision for one exact Linux
x86_64 glibc artifact. The candidate report evaluates all 22 PRD release
criteria: 21 pass, none fail, and the Android/iOS listener criterion is
`NOT_APPLICABLE_TO_LINUX_PROFILE` rather than a Linux pass.

The decision is bound to artifact SHA-256
`c0988f62eb657c465a928825573e41e2eb2675241240312bc2228482cbafc9ee`.
The report also binds the payload, source tree, provider manifest, build
fingerprint, SBOM, hosted release manifest, public API inventory and independent
review. A changed or missing input makes the gate fail instead of retaining an
old pass.

## Release evidence

- [`linux_x86_64/release-candidate.json`](linux_x86_64/release-candidate.json)
  is the machine-readable decision, criterion matrix and digest index.
- [`test-plan.md`](test-plan.md) defines 20 paths, 12 scenarios and 10 tests.
- [`test-results.md`](test-results.md) records the exact local commands and
  results.
- `task-check.json` records the four bounded task acceptance commands.
- `evidence.json` seals the candidate and task-check reports against the current
  task sources.

## Reused long-running evidence

M7-031 did not rerun long profiles. It verifies and reuses the formal M7-022
soak by its report and artifact digests: 86,400 requested seconds and
86,400.478 seconds of wall time. It also verifies the retained one-hour SSE
profile by digest. A short, preflight-only, interrupted, timed-out or
wrong-artifact run cannot satisfy the candidate gate.

## Boundaries

This decision covers Linux x86_64 glibc only. It does not complete the global
six-platform M7 work or claim Linux musl support. The API is pre-1.0, and the
staging draft Release used to transport frozen bytes for hosted attestation is
not itself the public stable Release. M7-031 does not depend on runtime, std,
stdx or SDK source changes.
