# M7-031 test results

Date: 2026-08-30

Platform: Linux x86_64 glibc 2.44

Repository validation toolchain: Cangjie `1.1.0-alpha.20260829040003`, CJPM
`1.1.3`

Frozen artifact toolchain: Cangjie `1.1.0-alpha.20260817040003`, CJPM `1.1.3`

## Results

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
