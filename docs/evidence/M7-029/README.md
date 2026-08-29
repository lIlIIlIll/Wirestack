# M7-029 evidence

## Status

INCOMPLETE

## Independent audit intake

The two supplied independent fixed-commit audit files are preserved under
[`independent-review-source/`](independent-review-source/). Their source hashes,
the one-byte JSON newline normalization, audited baseline, finding counts and
acceptance boundary are recorded in [`audit-intake.json`](audit-intake.json).
[`current-release-blockers.json`](current-release-blockers.json) carries the two
Critical and eleven High findings forward against the current review target.

The audit is valid independent static-analysis input. It is not renamed to
`independent-review.json` and is not treated as a final PASS: its baseline is
`49f3094`, it records that independent build/test execution was not completed,
and it lacks the reviewer metadata and current M7-028 digest binding required by
the M7-029 contract.

## Completed preparation

- [`test-plan.md`](test-plan.md) defines the review provenance, finding, closure,
  false-PASS, sensitive-data, and atomic-report paths.
- [`review-request.json`](review-request.json) binds the requested review to the
  exact M7-028 package digest.
- [`independent-review.template.json`](independent-review.template.json) gives
  the reviewer the strict report shape without pretending that a review exists.
- [`reviewer-instructions.md`](../../security/review/linux-1.0/reviewer-instructions.md)
  lists the required security domains and methods.
- The validation tool rejects missing or stale targets, incomplete scope,
  missing independence attestation, malformed findings, unresolved High or
  Critical findings, skipped regressions, sensitive values, and compatibility
  gating.
- A native AWS-LC regression now proves that a matching SPKI pin does not bypass
  reference-identity verification.
- The canonical AWS-LC provider manifest is now a repository-visible build input
  instead of an ignored local prerequisite, closing `WS-BUILD-001` in the current
  tree pending clean-checkout execution.
- HTTP/2 DATA permit transfer, SETTINGS role/default handling and cancellation
  wrappers now fail closed under their focused regressions.
- Authenticated CONNECT tunnels are single-lease when no stable credential
  identity is available, and ambiguous std.net write timeouts are never retried.
- Linux trust identities bind bounded content digests rather than path metadata.
- Cancelling one std.net accept no longer closes the listener. A delayed libc/NSS
  resolver job is quarantined behind a detached reaper so public close is bounded
  without freeing worker-reachable state.
- Resolver native-family decoding now accepts only explicit IPv4/IPv6 values,
  and pending polls use a bounded exponential backoff.
- The repository and release payload now declare Apache-2.0. The payload also
  carries the complete AWS-LC 5.5.0 `LICENSE` and `NOTICE`, and the SBOM binds
  their digests.
- `Clean Cangjie Build` defines the repository-side fail-closed PR job on
  GitHub-hosted `ubuntu-latest`. Actions use immutable revisions. The workflow
  resolves the latest complete Linux x64 nightly, validates its release/tag and
  required asset, then passes that exact version to the setup action for the
  run. A missing or malformed release fails closed instead of falling back.
  `repo-doctor` retains `DEGRADED` when optional GitButler/rp-rg capabilities
  are absent on the hosted runner; CI accepts only its stable READY or DEGRADED
  exit codes and still rejects BLOCKED.
  Hosted CI runs the shared current-source gate used by `scripts/check` for the
  architecture guard, native resolver build, `cjpm check`, build and
  non-performance tests. Historical release-evidence freshness remains
  fail-closed in `scripts/check` and is intentionally regenerated only after
  the security remediation candidate is frozen.

The first process-isolated review is preserved unchanged under
[`initial-isolated-review/`](initial-isolated-review/). It reviewed the clean
M7-028 commit `e19cd8e4a07e84e4da0a0a8648919b86e08684f8` and returned FAIL with
one Critical, ten High, and nine Medium findings. That result is remediation
input, not the final M7-029 report. The current implementation closes the
Critical and High source findings with focused regressions; a fresh isolated
review of the frozen candidate must independently confirm those dispositions.

The second process-isolated review is preserved unchanged under
[`second-isolated-review/`](second-isolated-review/). It reviewed candidate
`8e4a0e82f040b1befba1ecaff443069af4b85825` and independently confirmed nine
High findings as Fixed. It returned FAIL because `WS-CI-001` still lacked
remote GitHub enforcement and `WS-RES-001` still allowed unbounded accumulation
of quarantined pools. The resolver now reserves process-wide capacity for at
most eight live pools and 64 workers. A native wrapped-`getaddrinfo` probe proves
that the ninth quarantined pool fails closed and that capacity returns after
the blocked calls exit. A fresh review is still required after this source
change.

Current validation includes a 32-path, 30-scenario, 28-test plan with no matrix
issues; 13/13 M7-029 review-contract tests; 6/6 release, license, and SBOM
tests; a clean-CJPM native dependency hook check; a delayed-`getaddrinfo`
native gate with 9/9 focused Cangjie cases and a PASS process-wide capacity
probe; an architecture guard with zero violations;
and the complete serial non-Performance Cangjie suite with 570 PASS, 23 SKIPPED,
zero FAIL/ERROR out of 593. SKIPPED cases are not counted as PASS. The final
independent-review command still returns a non-PASS result because no conforming
current-target PASS review exists. Digest-bound raw outputs are under
[`regressions/`](regressions/), and
[`remediation-validation.json`](remediation-validation.json) records their
exact results and SHA-256 values.

## Remaining acceptance blockers

No conforming final independent reviewer report exists at
`docs/evidence/M7-029/independent-review.json`. The local gate therefore still
returns a non-PASS result. The preserved initial review is intentionally not
renamed to that path because it targets the pre-remediation snapshot and uses
the reviewer's original non-gating schema. The implementation agent cannot
invent final reviewer dispositions, metadata, or independent execution evidence.

GitHub required-check enforcement is now recorded as PASS in
[`github-required-check.json`](github-required-check.json). PR #94 ran the
GitHub-hosted clean checkout on exact head
`bd7f11bee8756ac70f74bbe5bb8d08eb492f09bf`; `clean-cangjie-build` completed
successfully in run `33233671568`. Active ruleset `21787899` protects main,
requires that exact check under a strict policy, prohibits deletion and
non-fast-forward updates, and has no bypass actors.

M7-029 becomes COMPLETE only after an independent reviewer submits a report for
the current package and every High or Critical finding is Fixed or proven Not
Applicable. Fixed findings need digest-bound, executed regression evidence.

## Deliberately unrun gates

- one-hour SSE profile;
- 86,400-second M7-022 release soak;
- final artifact rebuild and release signing;
- non-Linux platform validation.
