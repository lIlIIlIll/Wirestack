# M7-032 evidence

## Status

Historical M7-032 acceptance is recorded as COMPLETE at revision
`1816323cb2e87221e9b55d390aa1a42d9e5e98fa`; the original schema-v1 PASS seal
is preserved byte-for-byte in [`evidence.json`](evidence.json).

Current-source requalification: BLOCKED. The historical seal is not a current
PASS: the verifier rejects its schema version as `UNKNOWN_SCHEMA`; see
[`current-evidence-verification.json`](current-evidence-verification.json).

## Scope

M7-032 establishes public ownership for Wirestack contracts and removes direct
`wirestack.internal.*` exposure from public declarations. It intentionally
does not preserve the historical experimental API.

## Acceptance evidence

- [ADR-0006](../../architecture/adr/0006-public-contract-ownership.md) records
  the public ownership and acyclic dependency direction.
- [The API report](linux_x86_64/public-api.json) records 243 declarations, 103
  public-to-public aliases, zero internal aliases, and
  `NOT_EVALUATED_PRE_1_0` compatibility policy.
- [The clean-consumer report](linux_x86_64/clean-consumer.json) records native
  build and runtime PASS for HTTPS, existing-transport TLS, CONNECT, H1/H2
  server, SSE, custom CA, mTLS, and scoped cancellation.

The canonical [`evidence.json`](evidence.json) is the original M7-032 PASS
seal, preserved byte-for-byte. It retains the original revision, report
digests, and source digests. The referenced task-check digest (`9b0778d7…`)
does not match the currently available `task-check.json` (`c25a902c…`), and
the recorded revision is unavailable in this checkout and on GitHub. The seal
is archival evidence, not a newly verified current-source result. The current
verifier rejects the schema-v1 seal as `UNKNOWN_SCHEMA`; current-source
requalification remains BLOCKED.

The historical M7 API report and baseline remain unchanged because M7-031 and
the M7-028 security index consume their digests. The validator's bare default
uses a distinct current-source pair:
[`current-source/linux_x86_64/public-api-inventory.json`](current-source/linux_x86_64/public-api-inventory.json)
and
[`current-source/linux_x86_64/public-api.json`](current-source/linux_x86_64/public-api.json).
`--write` targets only that pair and refuses writes to either sealed historical
M7 path, including explicit path overrides. Alternate inventory/report pairs
must be supplied together. The
[`default-path-regression.json`](default-path-regression.json) records relative
root routing, historical-artifact protection, M11 pair routing, one-sided
override rejection, and stale-report rejection.

The current-source pair is intentionally a requalification output, not M7-032
task evidence. It is absent from this task's `source_paths` and
`required_evidence`, and the archived schema-v1 seal does not cover it.
Current-source requalification remains BLOCKED, so this generated pair is not a
sealed current acceptance result.

## Current verification and requalification limits

The focused API regression suite passes 3/3. The updated test plan validates
with 11 paths, 10 scenarios, and 7 tests. Both current-source API invocations
pass:

- `scripts/check-m7-032-public-api --write --json`
- `scripts/check-m7-032-public-api --json`

The report records 363 declarations, 114 resolved aliases, and zero internal
aliases. The generated current-source pair is separate from the sealed
243-declaration M7 report.

The [`isolated-pr-head-task-check.json`](isolated-pr-head-task-check.json) file
records the task gate run from the isolated remediation worktree. Its
`architecture-guard.stdout_excerpt` is normalized: the absolute checkout root
was replaced with `<repo-root>`, and the raw stdout log is not committed. This
file is not the historical `task-check.json` receipt or a revision-bound
qualification.

- Test-plan validation: PASS, 11/10/7.
- Ownership/fault-injection suite: FAIL; it reports the existing
  M10-004/M10-003 status-consistency assertion. The retained receipt omits the
  total test count, so no count is claimed.
- Architecture guard and current-source API inventory: PASS.
- Clean consumer: FAIL; offline AWS-LC provider preparation cannot resolve
  `HEAD`.
- `cjpm check`, `cjpm build`, and `cjpm test`: unavailable because `cjpm`
  cannot be executed in this environment.

No current-source task-gate PASS is claimed. The
[`current-evidence-verification.json`](current-evidence-verification.json)
records `UNKNOWN_SCHEMA` because the current verifier does not accept the
historical schema-v1 seal. The current API inventory PASS does not override
the task-level blockers. `task-check.json` remains the older receipt; it is
not the isolated current-source run and its digest does not match the
historical seal.

The repository-wide `scripts/check` remains outside this focused regression
run. The 86,400-second M7-022 soak, one-hour SSE profile, and other long gates
were not run for this requalification.

## Release evidence boundary

The repository-wide `scripts/check` was run after the ownership change and
failed closed because M7-019, M7-020, M7-021, M7-025, and the historical
M7-026 reports are bound to the earlier source or artifact. Those failures are
expected stale-evidence signals, not M7-032 PASS evidence. The final candidate
must regenerate affected artifact, installation, performance, SBOM, and audit
reports before the single final M7-022 soak.

One earlier default-parallel Cangjie run observed the existing H2 SSE profile
finish before its producer close became visible. The same case passed on an
immediate focused rerun, and the complete 584-case suite passed with
`--parallel 1`. M7-032 does not claim that default-parallel scheduling race is
resolved.

The 86,400-second M7-022 soak, one-hour SSE profile, and every other long gate
were not run by M7-032.
