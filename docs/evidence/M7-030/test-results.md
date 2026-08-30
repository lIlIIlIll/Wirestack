# M7-030 test results

Date: 2026-08-30

Platform: Linux x86_64 glibc 2.44

Toolchain: Cangjie `1.1.0-alpha.20260817040003`, CJPM `1.1.3`

## Local results

| Command | Result |
|---|---|
| `python3 tools/repository/repository_tooling.py --root . validate-tasks --json` | PASS; M7-030 task contract accepted. |
| `python3 tools/repository/repository_tooling.py --root . validate-plan docs/evidence/M7-030/test-plan.md --json` | PASS; 21 paths, 18 scenarios and 14 planned tests. |
| `python3 -m unittest tools.tests.test_m7_030_linux_release -v` | PASS; 12/12 tests. |
| `scripts/generate-m7-025-linux-supply-chain --validate-only` | PASS; artifact `c0988f62eb657c465a928825573e41e2eb2675241240312bc2228482cbafc9ee`, build fingerprint `67dcd09f0ab99a33cfb204fb5f2a133a911f8f706ccf85a7a3312b980ddac9d9`. |
| `scripts/release-m7-030-linux validate-workflow --output docs/evidence/M7-030/workflow-contract.json` | PASS; three attestation subjects and six immutable action references. |
| `scripts/check-m7-030-release` | PASS as `REHEARSAL`; three detached signatures, clean consumer, update, advisory and authorized rollback passed. Production attestation remains BLOCKED. |
| `scripts/check-fast --json --output build/m7-030/check-fast.json` | PASS; task-contract fast gate. |
| fixed-SDK `scripts/check` outside the restricted socket sandbox | PASS; Python tool tests, gate tests and benchmark tests passed; `cjpm check`, `cjpm build` and `cjpm test` passed. Cangjie summary: 592 total, 569 passed, 23 skipped by the repository's non-Performance selection, 0 error, 0 failed. The skipped cases are not reported as PASS. |

The first `scripts/check` attempt inside the restricted sandbox failed before
test execution because `std.unittest` could not create its local socket and
returned `SocketException: Operation not permitted`. The same command then ran
outside that socket restriction and passed. This was an environment failure,
not a source or assertion failure.

## Task-level result

`scripts/check-task M7-030 --json --output
docs/evidence/M7-030/task-check.json` ran all six commands. The first five
passed. `github-hosted-attestations` returned exit 2 with
`HOSTED_ATTESTATION_BLOCKED` because `github-attestation.json` does not yet
exist. The overall task result is therefore FAIL/INCOMPLETE, not PASS.

`scripts/verify-evidence M7-030 --json` also returned FAIL with
`PATH_MISSING` for `docs/evidence/M7-030/evidence.json`. Evidence is not sealed
before the hosted attestation and all task commands pass.

## Gates not run

- The GitHub-hosted OIDC/Sigstore workflow has not run because the task branch
  has not been pushed.
- The one-hour SSE profile was not run.
- A second 86,400-second soak was not run; M7-022 already owns and completed the
  final artifact soak.
- No SDK, runtime, std, stdx, non-Linux or self-hosted-runner gate was run.
