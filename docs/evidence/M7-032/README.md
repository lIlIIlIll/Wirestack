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
digests, and source digests. The task-check digest recorded by the seal
(`9b0778d7…`) matches no `task-check.json` in this tree: `main` carries
`c25a902c…` and the current committed receipt here is `f0867de4…`, which is
also `task_gate.task_check_sha256` in
[`current-source-requalification.json`](current-source-requalification.json).
The seal's recorded revision is unavailable in this checkout and on GitHub.
The seal is archival evidence, not a newly verified current-source result. The
current verifier rejects the schema-v1 seal as `UNKNOWN_SCHEMA`;
current-source requalification remains BLOCKED.

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

The inventory and the public API report are byte-identical to the base
revision. The [clean-consumer report](linux_x86_64/clean-consumer.json) is not:
this branch adds the `NO_FOLLOW_REDIRECT=PASS` marker, so its digest moves from
`140e6415…` to `557e5e99…`. The M7-031 candidate
(`release-candidate.json#evidenceIndex`), the M7-031 seal
(`evidence.json#source_sha256`), and the M7-028 security index
(`docs/security/review/linux-1.0/evidence-index.json#evidence`) still bind the
pre-PR `140e6415…` value. They are stale consumers, recorded as such in
`default-path-regression.json`, and are not rewritten here: refreshing them is
M7-031 and M7-028 requalification work, and this branch mints no replacement
acceptance digest. On this head the M7-028 index check therefore reports
`DIGEST_MISMATCH` for this path, and the M7-031 candidate gate is out of scope
for M7-032.

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

The [`isolated-pr-head-task-check.json`](isolated-pr-head-task-check.json)
retains the earlier standalone-branch failure, before the P1-012 (#220)
dependency-scope fix and M10-004 (#230) status correction were stacked. Its
architecture-guard excerpt is normalized to `<repo-root>`; raw logs are not
committed.

The current [`task-check.json`](task-check.json) records the full M7-032 task
gate on the stacked source with both parent fixes applied. All eight acceptance
commands pass: test-plan validation, ownership/fault-injection tests,
architecture guard, public API inventory, clean consumer, `cjpm check`,
`cjpm build`, and `cjpm test`.

- Test-plan validation: PASS, 11 paths, 10 scenarios, 7 tests.
- Ownership/fault-injection suite: PASS.
- Architecture guard and current-source API inventory: PASS; 363 declarations,
  114 resolved aliases, zero internal aliases.
- Native clean consumer: build and run PASS, including all ten HTTPS/TLS,
  H1/H2 server, SSE, CONNECT, custom-CA, mTLS, scoped-cancellation, and
  no-follow-redirect markers.
- `cjpm check`, `cjpm build`, and `cjpm test --exclude-tags=Performance`:
  PASS with the qualified STS 1.1.3 SDK. Offline AWS-LC 5.5.0 source was
  supplied from the verified clean commit
  `991e67ff4cf04df4dd89e407f8b920c6936cb56a`.

This gate is evidence for the stacked M7-032 source, not standalone PR #221
against `main` without its #220 and #230 parents. The current-source pair
remains outside `source_paths` and `required_evidence`; the original schema-v1
seal remains unchanged. `current-evidence-verification.json` still records
`UNKNOWN_SCHEMA` for that archival seal, so no current-source evidence-verifier
PASS or replacement canonical seal is claimed. The repository-wide
`scripts/check`, the 86,400-second M7-022 soak, one-hour SSE profile, and other
long gates were not run.

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
