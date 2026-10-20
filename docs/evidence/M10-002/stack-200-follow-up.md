# M10-002 current-source acceptance follow-up

This report records the current PR #216 candidate, including Q4 outbound HTTP/2 DATA admission. It supersedes the earlier Stack #200 follow-up results for this candidate. The historical report at `docs/evidence/M10-002/verification.json` remains unchanged and is not evidence for this source revision.

## Candidate and scope

- Source revision: `e82743ee2bfa16ee6160d3e0236d340cf2ad0b87` (M10-002 source and tests; exact pinned-CJDoc output is also committed).
- Platform: Linux x86_64 glibc.
- Toolchain: Cangjie 1.1.3, CJPM 1.1.3, cjdoc 0.7.2.
- Q4 behavior: query current stream flow-control credit before waiting for the owner buffer; size the initial lease request to that feasible credit, with a minimum of one DATA byte plus the 9-byte frame header. A blocked buffer wait retains no permit. After leasing, recheck credit; if it shrank, release the lease and retry at the smaller admissible size. Buffer-lease waits link caller cancellation with stream/controller termination. Reserve queue capacity before payload allocation and roll back admission state on rejection. Client DATA, duplex writes, normal server responses, and pushed responses use this path. Server response staging advances only after successful admission. Classic CONNECT without `:scheme` uses the actual HTTP/HTTPS transport scheme for resource ownership.
- No public API was added or changed.

Commit `e82743ee2bfa16ee6160d3e0236d340cf2ad0b87` contains the source and regression fixes for the current candidate. Evidence is bound to this source revision; no M10-003 or downstream task-manifest changes are included.

The full revision-bound results are in `docs/evidence/M10-002/stack-200-review/verification.json`; scenario coverage is in `scenario-matrix.json`. The strict generated-doc report is `docs-report.json`.

## Review finding closure

The P2 finding was that a 10-byte DATA lease minimum (9-byte frame header plus at least one DATA byte) could never fit a valid 9-byte route or origin cap. The previous code waited indefinitely under a background context, retaining a waiter and owner.

Commit `e82743ee2bfa16ee6160d3e0236d340cf2ad0b87` computes the statically configured DATA-buffer ceiling and rejects an impossible minimum as `ResourceExhausted / PoolAcquire / Retryability.Never` before cancellation registration, waiter creation, or owner allocation. Live resource exhaustion remains waitable.

The regression test failed before the fix: both route-cap=9 and origin-cap=9 cases timed out, `highWaterAdmissionWaiters` became 1, and `rejectedOperations` stayed 0. The exact isolated command now exits 0 with 1 passed, 15 skipped; it also proves exact 10-byte capacity succeeds. An independent read-only subagent reviewed the exact pushed head and reported no findings.

## Current acceptance results

| Gate | Result |
|---|---|
| `python3 tools/architecture_guard.py --root . --format text` | Exit 0; PASS. |
| `python3 tools/check_network_capabilities.py --check` | Exit 0; static contract PASS. Native capability execution was not run by this check. |
| `cjpm check` | Exit 0; PASS. |
| `cjpm build` | Exit 0; PASS; compiler emitted unreachable-block warnings, no build errors. |
| `cjpm test --exclude-tags=Performance --parallel 1 --no-progress --no-color` (run by `scripts/check-code`) | Exit 0; 1,079 passed, 28 skipped, 0 errors, 0 failures (1,107 total). |
| HTTP/2 resource profiles | `RLIMIT_NOFILE=64`, `RLIMIT_DATA=1 GiB`, and `RLIMIT_AS=4 GiB` each passed 215/215. CPU affinity 0 first failed `Http2ClientConnectionTest.queuedHalfCloseCancellationDoesNotWaitForConnectionWriter` (214/215; same-direction operation already active / transport direction closed); the immediate identical retry passed 215/215. |
| Strict generated documentation | Current-source `scripts/check-code` passed with pinned CJDoc 0.7.2; 1,873/1,873 API symbols and 950/950 parameters across seven layers. Generated docs and checked-in `docs/api/generated/docs.json` both SHA-256 `c0b3f311e670e8c983e280b1b312ab0b1d2c22df9cee6a44f188bbeb9272348c`; no public API/docs change. |
| GitHub CI on source commit `e82743ee2bfa16ee6160d3e0236d340cf2ad0b87` | All 10 workflows passed on the exact pushed head, including [Clean Cangjie Build](https://github.com/lIlIIlIll/Wirestack/actions/runs/39468864649) and [M7-033 Developer Documentation](https://github.com/lIlIIlIll/Wirestack/actions/runs/39468864637); complete run IDs are in `verification.json`. |
| `scripts/check` | Re-run on source revision `e82743ee2bfa16ee6160d3e0236d340cf2ad0b87`; exit 1 in initial tooling unittest stage: 584 tests, 25 failures, 16 errors, 4 skipped. Failure families: stale AWS-LC advisory disposition, M3-031 provider fixtures/error codes, M7-030 release/evidence digests, M12-002 platform-support source, and M7 task-graph expectations. |
| `python3 tools/repository/repository_tooling.py --root . check task M10-002 --json` | Re-run on source revision `e82743ee2bfa16ee6160d3e0236d340cf2ad0b87`; exit 2, INVALID with `DEPENDENCY_INCOMPLETE`: the global task validator reports downstream M10-003 depending on BLOCKED M10-002. M10-002 declares M9-001, which is COMPLETE; M10-004 is also COMPLETE while M10-003 is BLOCKED. Neither #175 nor M10-004 was modified. |

The earlier clean-build run `39448838666` failed source-tree mutation rejection at `b031cfd545e375b3a13f747c8eafe616bee5309e`: checked-in `docs.json` differed from the exact CI-pinned CJDoc output. The output was regenerated and committed at `2eb92251a0a600c974dc6c59b2313c806e660e5e`; current-source local strict verification and the final e82743ee2bfa CI run pass. The separate failure on the intermediate 2eb92251 head is retained in `verification.json`.

An earlier full-suite attempt in this acceptance sequence timed out in `Http2ConnectionPoolTest.saturatedCrossOriginWaiterDrainsHttp2ConnectionBeforeSameKeyRefill`; the isolated case passed 1/1. A prior single-CPU profile failed the GOAWAY `activeStreamCount` assertion before the identical retry passed. On the current revision, the CPU profile had a separate cancellation/writer-direction failure before the immediate retry passed. These are stability risks, not unconditional passes.

The noncanonical data-limit attempt with an extra `cjHeapSize=1GB` override exited 134 before tests because the runtime allocator could not create a page. An earlier default-heap profile passed 213/213; it is historical and is not counted as current-source evidence.

An intermediate full run before correcting newly added scheduler test budgets exited 1 with 1,073 passed, 28 skipped, and three errors. Those tests exhausted their reserved inbound-window budget; the test limits were corrected, and the final current-source full run passed 1,079/1,107 with zero errors.

## Status and boundaries

M10-002 remains **BLOCKED** until the repository-wide `scripts/check` and global task-graph gate are clear. PR #216 remains open and draft; it must not be marked ready from the passing Q4-specific, native, or GitHub CI gates alone. The public PR body remains stale: it cites revision `7915e84f89182eac40e0f361fcf4c58b8818732e`, old test/profile totals, an old docs hash, and obsolete #215 stacking details. The GitHub CLI is unauthenticated, `xd://github` has no PR-edit operation, and a previous GitButler description sync failed with “Failed to get pull request”; the body could not be refreshed. Issue #174 remains open and untouched. M10-003 / issue #175 was not started or modified. No platform other than Linux x86_64 glibc is claimed.
