# M10-002 current-source acceptance follow-up

This report records the current PR #216 candidate, including Q4 outbound HTTP/2 DATA admission. It supersedes the earlier Stack #200 follow-up results for this candidate. The historical report at `docs/evidence/M10-002/verification.json` remains unchanged and is not evidence for this source revision.

## Candidate and scope

- Source revision: `e72bbb3c8a10670b716dcf263cdafff052102b84` (Q4 source and regression tests).
- Platform: Linux x86_64 glibc.
- Toolchain: Cangjie 1.1.3, CJPM 1.1.3, cjdoc 0.7.2.
- Q4 behavior: for positive current flow credit, cap the DATA frame to that credit, wait for the exact owner-buffer lease, recheck credit, then acquire the flow-control permit. If credit is zero, wait without retaining a managed buffer; after credit returns, acquire a lease non-blockingly or release the permit and retry through the buffer-first wait path. Stream/controller termination cancels pending lease waiters. Classic CONNECT without `:scheme` uses the actual `http` or `https` transport scheme for resource ownership.
- No public API was added or changed.

Commit `e72bbb3c8a10670b716dcf263cdafff052102b84` contains the current Q4 source and regression-test fixes. The revision-bound reports include the complete current-source run; no public API or M10-003/downstream task manifest changed.

The full revision-bound results are in `docs/evidence/M10-002/stack-200-review/verification.json`; scenario coverage is in `scenario-matrix.json`. The current strict documentation report is `docs-report.json` (CJDoc 0.7.2, PASS: 1,873/1,873 symbols and 950/950 parameters). The report records generated output; the checker’s format-only rewrite of checked-in `docs.json` was restored because the public API is unchanged.

## Review finding closure

The earlier P2 finding was that the 10-byte DATA lease minimum could not fit a route or origin cap of 9; the previous code waited and retained a waiter and owner. Commit `e82743ee2bfa16ee6160d3e0236d340cf2ad0b87` rejects that impossible minimum as `ResourceExhausted / PoolAcquire / Retryability.Never` before cancellation registration, waiter creation, or owner allocation. The pre-fix route-cap and origin-cap regression timed out; the post-fix run passed 1/16 with 15 skipped and confirmed exact 10-byte capacity succeeds.

The new P2 source finding was that `tryReserveSend` did not retain the caller `OperationContext` on its fast-path permit. After a peer SETTINGS shrink, the background writer emitted backpressure events without caller observation identifiers. Commit `5d6b2c7358e08169ede6198b472b37d773e017d` assigns `observationContext` when the caller has an event sink, before transferring the buffer lease. The focused regression failed before the fix (0 passed, 215 skipped, 1 failed) and passed after it (1 passed, 215 skipped). Start/completion events retained the caller trace, request, attempt, connection, stream, and `RequestWrite` stage; permit and managed-buffer usage returned to zero.

The other P2 finding was that `src/internal/http_resource_budget_test.cj` was missing from the M10-002 `allowed_paths` and `source_paths`. Both inventories now include it. Independent read-only subagents `Q4PermitReview` and `Q4EvidenceBindingReview` inspected the fixed source, test, and manifest diff; both reported no new findings and ran no builds or tests.

The repaired #216 Q4 source-review findings are:

- The DATA slice is capped to currently feasible stream credit before a blocking owner-buffer lease wait. The strengthened regression fills the owner budget to 34,422 of 34,431 bytes, leaving less than the 10-byte minimum; it proves the blocked write does not hold flow credit and is admitted at 16,384 bytes after capacity returns.
- A pending owner-buffer waiter is linked to stream/controller termination. Existing deterministic tests prove stream close and flow-controller close wake the waiter and leave no retained admission state.
- Classic CONNECT omits `:scheme`; a real in-memory client/server test now verifies owner origins use the actual `http` or `https` transport scheme.

The full HTTP/2 suite includes these cases; all 218 cases pass under each required resource profile.

## Draft PR re-review

Four independent read-only subagents reviewed all four open draft PRs at these exact heads. Each reported no findings.

| PR | Reviewed head | Result |
|---|---|---|
| #215 | `2a04a1c1fa2fc2bdc8d6433aac6f253004b4f81d` | No findings |
| #216 | `e6590ee111449977fb732edaf42164ffb7c265a3` | No findings |
| #220 | `a1dd89c4364de272d4ff79e3332ed9e6bb340475` | No findings |
| #221 | `e76c3ba4301472fd2272aed3a96e7dc64dac5bf6` | No findings |

The re-review did not clear the repository/tooling or task-dependency blockers.

## Current acceptance results

| Gate | Result |
|---|---|
| `python3 tools/architecture_guard.py --root . --format text` | Exit 0; PASS. |
| `python3 tools/check_network_capabilities.py --check` | Exit 0; static contract PASS. Native capability execution was not run by this check. |
| `cjpm check` | Exit 0; PASS. |
| `cjpm build` | Exit 0; PASS; compiler emitted unreachable-block warnings, no build errors. |
| `cjpm test --exclude-tags=Performance --parallel 1 --no-progress --no-color` | Exit 0; 1,082 passed, 28 skipped, 0 errors, 0 failures (1,110 total). |
| HTTP/2 resource profiles | `RLIMIT_NOFILE=64`, `RLIMIT_DATA=1 GiB`, `RLIMIT_AS=4 GiB`, and CPU affinity 0 each passed 218/218 with no skips, errors, or failures on the first attempt. |
| Strict generated documentation | `env cjHeapSize=1GB scripts/check-docs --json --output docs/evidence/M10-002/stack-200-review/docs-report.json` — PASS; 1,873/1,873 symbols and 950/950 parameters documented. |
| `scripts/check` | Exit 1 in its initial tooling unittest stage: 584 tests, 25 failures, 16 errors, 4 skipped. Failure families: stale AWS-LC advisory, M3-031 provider fixtures/error codes, M7-030 release/evidence digests, M12-002 platform-support source, and M7 task-graph expectations. |
| Task validator | `python3 tools/repository/repository_tooling.py --root . check task M10-002 --json` — exit 2, `INVALID / DEPENDENCY_INCOMPLETE`; the validator reports downstream M10-003 depending on blocked M10-002. M10-003/#175 and M10-004 were not modified. |

The earlier clean-build run `39448838666` failed source-tree mutation rejection at `b031cfd545e375b3a13f747c8eafe616bee5309e`: checked-in `docs.json` differed from the exact CI-pinned CJDoc output. The output was regenerated and committed at `2eb92251a0a600c974dc6c59b2313c806e660e5e`. All 10 workflows passed on later heads `e82743ee2bfa16ee6160d3e0236d340cf2ad0b87` and `f4034849f9d74c3301ccd0a1f3527909d057886f`. On exact source-bearing PR head `e6590ee111449977fb732edaf42164ffb7c265a3`, all 10 workflows passed, including Clean Cangjie Build and M7-033 Developer Documentation. The current strict local documentation check also passed on source revision `e72bbb3c8a10670b716dcf263cdafff052102b84`; earlier combined-check allocation failures are historical and do not supersede this direct pass.

The earlier full-suite pool-fairness timeout passed when rerun as an isolated case. An earlier single-CPU profile also had a GOAWAY `activeStreamCount` failure before an identical retry passed. Those are historical stability risks; the current full native run passed 1,082/1,110, and all current resource profiles passed 218/218 on the first attempt.

The noncanonical data-limit attempt with an extra `cjHeapSize=1GB` override exited 134 before tests because the runtime allocator could not create a page. An earlier default-heap profile passed 213/213; it is historical and is not counted as current-source evidence.

An intermediate full run before correcting newly added scheduler test budgets exited 1 with 1,073 passed, 28 skipped, and three errors. Those tests exhausted their reserved inbound-window budget; the test limits were corrected. The later e82743ee2bfa16ee6160d3e0236d340cf2ad0b87 full run passed 1,079/1,107; the 5d6b2c7358e08169ede6198b472b37d773e017d run passed 1,080/1,108; the current e72bbb3c8a10670b716dcf263cdafff052102b84 run passed 1,082/1,110.

## Status and boundaries

M10-002 remains **BLOCKED**. Current-source build, full native tests, four HTTP/2 resource profiles, strict docs, and all 10 workflows on source-bearing PR head `e6590ee111449977fb732edaf42164ffb7c265a3` pass. `scripts/check` fails in unrelated repository tooling tests and the task validator returns INVALID on the downstream M10-003 dependency. The final all-draft re-review found no findings on exact heads #215 `2a04a1c1fa2fc2bdc8d6433aac6f253004b4f81d`, #216 `e6590ee111449977fb732edaf42164ffb7c265a3`, #220 `a1dd89c4364de272d4ff79e3332ed9e6bb340475`, and #221 `e76c3ba4301472fd2272aed3a96e7dc64dac5bf6`. PR #216 is **OPEN and DRAFT**, stacked on #215. Issue #174 remains open. M10-003 / issue #175 was not started or modified. No platform other than Linux x86_64 glibc is claimed.
