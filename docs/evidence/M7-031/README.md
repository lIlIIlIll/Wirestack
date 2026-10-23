# M7-031 Linux release candidate

Status: **BLOCKED**

M7-031 is the gate that issues a `GO_FOR_LINUX_STABLE_RELEASE` decision for
one exact Linux x86_64 glibc artifact. It is **BLOCKED** on two independent
grounds, so it issues no current GO decision.

1. Its declared prerequisite M7-030 is `BLOCKED`. The committed 2026-08-30
   M7-030 hosted report predates the required `signedPayloadSha256` subject,
   so M7-030's own gate reports `HOSTED_REPORT_SUBJECT`, and the retired
   attestation workflow cannot regenerate it while M8-007 is the active
   signer. The candidate gate therefore stops at
   `DEPENDENCY_INCOMPLETE: M7-030`.
2. The same missing `signedPayloadSha256` subject makes the retained
   2026-08-30 candidate report unsupported on current source: running the
   generator against the committed documents fails `DIGEST_INVALID` on the
   `M7-030` signed payload rather than reproducing a GO report.

The 2026-08-30 `GO_FOR_LINUX_STABLE_RELEASE` report stays in
[`linux_x86_64/release-candidate.json`](linux_x86_64/release-candidate.json)
as history for the artifact below. It is not a current verdict for this tree.
The candidate report evaluated all 22 PRD release criteria when generated:
21 pass, none fail, and the Android/iOS listener criterion is
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
- [`test-plan.md`](test-plan.md) defines 21 paths, 13 scenarios and 11 tests,
  including the blocked-prerequisite path.
- [`test-results.md`](test-results.md) records the exact local commands and
  results.
- `task-check.json` and `evidence.json` are the 2026-08-30 task gate and seal.
  They are retained byte-identically as history; both record `PASS` for a tree
  whose dependency M7-030 was `COMPLETE` at the time, so neither is a current
  acceptance result. They are not resealed on this branch because
  `seal_evidence` refuses a non-`PASS` acceptance status and no current PASS is
  claimed.
- [`task-check-current.json`](task-check-current.json) records the current
  `INVALID` task gate with zero commands because M7-030 is BLOCKED;
  [`evidence-check-current.json`](evidence-check-current.json) records the
  corresponding current evidence-freshness failure. Neither is a PASS seal.
- Both current receipts are declared in `tools/tasks/M7-031.json` under
  `source_paths` and `required_evidence`. Deleting either file therefore fails
  manifest validation with `PATH_MISSING` instead of quietly shrinking the
  task's surface, and a future reseal has to digest them. The 2026-08-30 seal
  predates that manifest change, so its `source_sha256` inventory is stale and
  is not resealed here; the current gate receipts stay as the record of the
  blocked state.

## Reused long-running evidence

M7-031 did not rerun long profiles. It verifies and reuses the formal M7-022
soak by its report and artifact digests: 86,400 requested seconds and
86,400.478 seconds of wall time. It also verifies the retained one-hour SSE
profile by digest. A short, preflight-only, interrupted, timed-out or
wrong-artifact run cannot satisfy the candidate gate.

## Why the suite skips

`tools/tests/test_m7_031_linux_candidate.py` checks the declared dependencies
before building the candidate. While any dependency is not `COMPLETE` it
raises `unittest.SkipTest` naming the unmet task, so repository-wide test
discovery stays meaningful instead of erroring in `setUpClass`. The
`M7031DependencyReadinessTests` cases always run and prove both directions on
temporary `status.md` fixtures: a `COMPLETE` prerequisite proceeds, and a
`BLOCKED`, `IN_PROGRESS`, `READY` or absent prerequisite row fails closed with
the task ID. Once M7-030 returns to `COMPLETE`, the fifteen candidate cases
execute again with no test change.

## Boundaries

This decision covers Linux x86_64 glibc only. It does not complete the global
six-platform M7 work or claim Linux musl support. The API is pre-1.0, and the
staging draft Release used to transport frozen bytes for hosted attestation is
not itself the public stable Release. M7-031 does not depend on runtime, std,
stdx or SDK source changes.
