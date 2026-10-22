# M7-031 test results

Date: 2026-08-30 (historical); 2026-10-22 (dependency-readiness rerun)

Platform: Linux x86_64 glibc 2.44

Repository validation toolchain: Cangjie `1.1.0-alpha.20260829040003`, CJPM
`1.1.3`

Frozen artifact toolchain: Cangjie `1.1.0-alpha.20260817040003`, CJPM `1.1.3`

## Historical results

The table below records the 2026-08-30 tree. It is retained unchanged as
history; [`README.md`](README.md) explains why M7-031 is now BLOCKED and why
these numbers are not a current verdict. The gate could not be reproduced on
current source: `scripts/check-m7-031-release` stops at
`DEPENDENCY_INCOMPLETE: M7-030` because M7-030 is BLOCKED, and before that
reclassification it already failed `DIGEST_INVALID: M7-030 artifact signed
payload`.

| Command | Result |
|---|---|
| `python3 tools/repository/repository_tooling.py --root . validate-plan docs/evidence/M7-031/test-plan.md --json` | PASS; 20 paths, 12 scenarios and 10 planned tests. |
| `python3 -m unittest tools.tests.test_m7_031_linux_candidate -v` | PASS; 11/11 tests. |
| `python3 -m unittest tools.tests.test_m7_linux_task_graph -v` | PASS; 6/6 tests. |
| `scripts/check-m7-031-release` | PASS; `GO_FOR_LINUX_STABLE_RELEASE`, 21 PASS, 0 FAIL and 1 Linux-profile N/A criterion. |
| `scripts/check-task M7-031 --json --output docs/evidence/M7-031/task-check.json` | PASS; 4/4 bounded acceptance commands. |
| `scripts/verify-evidence M7-031 --json` | PASS; two indexed reports, 27 source digests and no stale path. |
| `cangjie_env dynamic` then `scripts/check` outside the restricted socket sandbox | PASS; 218 repository-tool tests, 134 gate tests and 24 benchmark-tool tests passed. `cjpm check`, `cjpm build` and `cjpm test` passed. Cangjie summary: 592 total, 569 passed, 23 skipped by the non-Performance selection, 0 error and 0 failed. The skipped cases are not reported as PASS. |

The fault-injection suite rejects missing, duplicate, unknown and `SKIPPED`
criteria; cross-report artifact mismatches; short, preflight-only, interrupted
and wrong-artifact soak reports; unresolved High or Critical findings;
historical or internal-leaking API inventories; source drift; duplicate JSON
keys; unknown schemas; path escape; incomplete hosted subjects; and failed
atomic report replacement.

The first `scripts/check` attempt inside the restricted sandbox failed before
Cangjie test execution because `std.unittest` could not create its local socket
and returned `SocketException: Operation not permitted`. The same command then
ran outside that socket restriction and passed. This was an environment
failure, not a source or assertion failure.

## Long and out-of-scope gates

- The one-hour SSE profile was not rerun. Its retained report is verified by
  digest.
- The 86,400-second soak was not rerun. M7-022 already completed it for the
  exact candidate artifact, and M7-031 verifies that identity.
- No SDK, runtime, std, stdx, Linux musl or non-Linux gate was run.

## Dependency readiness (2026-10-22)

`tools/m7_031_linux_candidate.py` now exposes
`unmet_dependencies(root)`, and `validate_dependency_status` reports the first
unmet declared dependency through it. The unit suite reads that helper in
`setUpClass`: while a prerequisite is not `COMPLETE` the fifteen candidate cases
are skipped with the task ID, instead of raising from `setUpClass` and turning
repository-wide discovery into an error. The four
`M7031DependencyReadinessTests` cases run unconditionally on temporary
`status.md` fixtures.

| Command | Result |
|---|---|
| `python3 tools/repository/repository_tooling.py --root . validate-plan docs/evidence/M7-031/test-plan.md --json` | PASS; 21 paths, 13 scenarios and 11 planned tests. |
| `python3 -m unittest tools.tests.test_m7_031_linux_candidate -v` | PASS (1 skip); the four readiness cases pass and `M7031LinuxCandidateTests` reports `skipped 'M7-031 prerequisites are not COMPLETE: M7-030'`. |
| `python3 -m unittest tools.tests.test_m7_linux_task_graph -v` | FAIL; 5/6 tests. `test_evolution_status_matches_readiness_classification` reports `AssertionError: 'COMPLETE' != 'BLOCKED'` for `M10-004`, whose declared dependency M10-003 is BLOCKED. The identical failure occurs on the unmodified base commit `d496a242`, because that edge is M10-003/M10-004, so it is not caused by this branch and the assertion is not weakened here. |
| `scripts/check-m7-031-release` | FAIL; `M7-031 candidate: FAIL: DEPENDENCY_INCOMPLETE: M7-030`. |
| `scripts/verify-evidence M7-031 --json` | FAIL; `{"issues":[{"code":"DEPENDENCY_INCOMPLETE","detail":"M7-031 dependency is not COMPLETE: M7-030"}],"status":"FAIL"}`. |
| `scripts/check-task M7-031 --json` | INVALID; the requested task's closure contains the unmet `M7-030` dependency, so no acceptance command runs. |

`docs/evidence/M7-031/evidence.json` and `docs/evidence/M7-031/task-check.json`
are the 2026-08-30 seals and are retained byte-identically as history. They are
not resealed, because `seal_evidence` refuses a non-PASS acceptance status and
this branch makes no current PASS claim.
