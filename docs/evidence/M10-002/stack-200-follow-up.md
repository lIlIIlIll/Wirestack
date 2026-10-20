# M10-002 current-source acceptance follow-up

This report records the current PR #216 candidate, including Q4 outbound HTTP/2 DATA admission. It supersedes the earlier Stack #200 follow-up results for this candidate. The historical report at `docs/evidence/M10-002/verification.json` remains unchanged and is not evidence for this source revision.

## Candidate and scope

- Source revision: `5d6b2c7358e08169ede6198b472b37d773e017d` (M10-002 source, tests, and task-manifest evidence fix).
- Platform: Linux x86_64 glibc.
- Toolchain: Cangjie 1.1.3, CJPM 1.1.3, cjdoc 0.7.2.
- Q4 behavior: query current stream flow-control credit before waiting for the owner buffer; size the initial lease request to that feasible credit, with a minimum of one DATA byte plus the 9-byte frame header. A blocked buffer wait retains no permit. After leasing, recheck credit; if it shrank, release the lease and retry at the smaller admissible size. Buffer-lease waits link caller cancellation with stream/controller termination. A fast-path permit retains the caller `OperationContext` when an event sink exists, so backpressure events emitted after a SETTINGS shrink preserve caller identifiers. Reserve queue capacity before payload allocation and roll back admission state on rejection. Client DATA, duplex writes, normal server responses, and pushed responses use this path. Server response staging advances only after successful admission. Classic CONNECT without `:scheme` uses the actual HTTP/HTTPS transport scheme for resource ownership.
- No public API was added or changed.

Commit `5d6b2c7358e08169ede6198b472b37d773e017d` contains the Q4 source/test fix and the M10-002 evidence-inventory correction. Evidence is bound to this source revision; no M10-003 or downstream task-manifest changes are included.

The full revision-bound results are in `docs/evidence/M10-002/stack-200-review/verification.json`; scenario coverage is in `scenario-matrix.json`. `docs-report.json` records an earlier strict generated-doc pass and is not evidence that the current combined check passed.

## Review finding closure

The earlier P2 finding was that the 10-byte DATA lease minimum could not fit a route or origin cap of 9; the previous code waited and retained a waiter and owner. Commit `e82743ee2bfa16ee6160d3e0236d340cf2ad0b87` rejects that impossible minimum as `ResourceExhausted / PoolAcquire / Retryability.Never` before cancellation registration, waiter creation, or owner allocation. The pre-fix route-cap and origin-cap regression timed out; the post-fix run passed 1/16 with 15 skipped and confirmed exact 10-byte capacity succeeds.

The new P2 source finding was that `tryReserveSend` did not retain the caller `OperationContext` on its fast-path permit. After a peer SETTINGS shrink, the background writer emitted backpressure events without caller observation identifiers. Commit `5d6b2c7358e08169ede6198b472b37d773e017d` assigns `observationContext` when the caller has an event sink, before transferring the buffer lease. The focused regression failed before the fix (0 passed, 215 skipped, 1 failed) and passed after it (1 passed, 215 skipped). Start/completion events retained the caller trace, request, attempt, connection, stream, and `RequestWrite` stage; permit and managed-buffer usage returned to zero.

The other P2 finding was that `src/internal/http_resource_budget_test.cj` was missing from the M10-002 `allowed_paths` and `source_paths`. Both inventories now include it. Independent read-only subagents `Q4PermitReview` and `Q4EvidenceBindingReview` inspected the fixed source, test, and manifest diff; both reported no new findings and ran no builds or tests.

## Current acceptance results

| Gate | Result |
|---|---|
| `python3 tools/architecture_guard.py --root . --format text` | Exit 0; PASS. |
| `python3 tools/check_network_capabilities.py --check` | Exit 0; static contract PASS. Native capability execution was not run by this check. |
| `cjpm check` | Exit 0; PASS. |
| `cjpm build` | Exit 0; PASS; compiler emitted unreachable-block warnings, no build errors. |
| `cjpm test --exclude-tags=Performance --parallel 1 --no-progress --no-color` | Exit 0; 1,080 passed, 28 skipped, 0 errors, 0 failures (1,108 total). |
| HTTP/2 resource profiles | `RLIMIT_NOFILE=64`, `RLIMIT_DATA=1 GiB`, `RLIMIT_AS=4 GiB`, and CPU affinity 0 each passed 216/216 with no skips, errors, or failures on the first attempt. |
| Strict generated documentation | Current-source `scripts/check-code` exited 1 twice at the combined CJDoc 0.7.2 check because allocation failed (13,779,556 bytes, then 9,186,376 bytes). Per-package coverage and rendering passed. The checked-in `docs-report.json` is an earlier pass, not current evidence. No public API changed. |
| GitHub CI | All 10 workflows passed on the previous pushed source commit `e82743ee2bfa16ee6160d3e0236d340cf2ad0b87`. The current source commit `5d6b2c7358e08169ede6198b472b37d773e017d` has not been pushed, so it has no CI result yet. |
| `scripts/check` | Current-source run exited 1 in the initial tooling unittest stage: 584 tests, 25 failures, 16 errors, 4 skipped. Failure families: stale AWS-LC advisory, M3-031 provider fixtures/error codes, M7-030 release/evidence digests, M12-002 platform-support source, and M7 task-graph expectations. |
| `python3 tools/repository/repository_tooling.py --root . check task M10-002 --json` | Current-source run exited 2, INVALID with `DEPENDENCY_INCOMPLETE`: downstream M10-003 depends on BLOCKED M10-002. M10-002 declares M9-001, which is COMPLETE. M10-004 is also COMPLETE while M10-003 remains BLOCKED. #175 and M10-004 were not modified. |

The earlier clean-build run `39448838666` failed source-tree mutation rejection at `b031cfd545e375b3a13f747c8eafe616bee5309e`: checked-in `docs.json` differed from the exact CI-pinned CJDoc output. The output was regenerated and committed at `2eb92251a0a600c974dc6c59b2313c806e660e5e`. All 10 recorded workflows then passed on the later pushed `e82743ee2bfa16ee6160d3e0236d340cf2ad0b87` commit. Those results are historical and do not cover the current `5d6b2c7358e08169ede6198b472b37d773e017d` commit.

The earlier full-suite pool-fairness timeout passed when rerun as an isolated case. An earlier single-CPU profile also had a GOAWAY `activeStreamCount` failure before an identical retry passed. The CPU profile on `e82743ee2bfa16ee6160d3e0236d340cf2ad0b87` had a separate cancellation/writer-direction failure before retry. All four profiles on the current source revision passed 216/216 on the first attempt.

The noncanonical data-limit attempt with an extra `cjHeapSize=1GB` override exited 134 before tests because the runtime allocator could not create a page. An earlier default-heap profile passed 213/213; it is historical and is not counted as current-source evidence.

An intermediate full run before correcting newly added scheduler test budgets exited 1 with 1,073 passed, 28 skipped, and three errors. Those tests exhausted their reserved inbound-window budget; the test limits were corrected. The later e82743ee2bfa16ee6160d3e0236d340cf2ad0b87 full run passed 1,079/1,107; the current 5d6b2c7358e08169ede6198b472b37d773e017d run passed 1,080/1,108.

## Status and boundaries

M10-002 remains **BLOCKED**. `scripts/check` still fails in repository tooling tests, the current combined strict-documentation check failed twice from allocation errors, and the task validator remains INVALID because downstream M10-003 depends on M10-002 being COMPLETE. PR #216 remains open and draft; do not mark it ready. Its public description is stale and could not be updated through available authenticated routes. Issue #174 remains open. M10-003 / issue #175 was not started or modified. No platform other than Linux x86_64 glibc is claimed.
