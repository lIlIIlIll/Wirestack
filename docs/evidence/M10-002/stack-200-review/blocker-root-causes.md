# M10-002 repository and task-gate blocker analysis

## Evidence boundary

The current M10-002 Q4 source revision is `e7c4bba5faf568317edd580e26eef118cc59057d`; the P1-012 dependency-scope fix from #220 is present in the local #216 ancestry. Current-source acceptance is recorded in `current-source-acceptance.json`. The historical targeted repository diagnostic remains bound to candidate `b872f1b8304a16a769a517efa8cdf566e20ff963` and records 122 tests, 25 failures, 16 errors, and 0 skips. A read-only root-cause follow-up inspected candidate `8f7903125934962621ee27d328b68a0d2233972a` (tree `a2bd279d376f6f20e539697802f0f1cabbd5c3ec`); it made no retained source, evidence, or fixture changes.

The follow-up reproduced the same 122-test result. It also applied the four non-fabricating owner corrections only in memory or reverted scratch paths; that diagnostic then reported 122 tests passing. This is causal analysis, **not** a repository `scripts/check` pass, an M10-002 task-gate pass, or durable owner evidence. The scratch fixture was removed.

## Repository-wide check blockers

| Family | Confirmed root cause | Owning correction | Boundary |
|---|---|---|---|
| TLS provider validation (19 failures, 6 errors) | All three provider records retain `reviewed_through = 2026-08-31T17:30:00Z`; the 31-day advisory-intake expiry rejects validation before later negative and positive assertions run. | M0-016 performs the actual advisory review across the documented intake channels, updates provider disposition only with authoritative review evidence, then regenerates retained M0-016/M3-031 results. | Do not bump the date, IDs, or approval state without the security review. A disposition-only edit also leaves retained-result source-object and Windows license-byte digest mismatches. |
| M3-031 desktop evidence (4 failures, 2 errors) | The stale-advisory exception is mapped to `RAW_RESULT` before the intended `PLATFORM`, `LICENSE_BUNDLE`, and `STALE_REVISION` assertions; the exact-native-result cases fail at the same earlier validation. Separately, the on-disk hosted run is `STALE_SOURCE`: its recorded `run.py` / `validate.py` digests predate the current scripts. | M3-031 and M0-016 refresh the provider inputs, rerun the hosted desktop workflow, and retain new `hosted-run.json`, `provider-result.json`, and validation evidence. | The validation error mapping is not the root defect. The hosted-run digest gap is not covered by the current unit fixtures; its owner must add source-bound evidence checks. |
| M7-030 release/evidence (8 errors) | The suite reads `dist/m7-021/wirestack-0.1.0-linux-x86_64-glibc.tar.gz`, which is ignored and absent in a clean checkout. The artifact is available only from the frozen staging tag `m7-030-frozen-artifact-c0988f62`; the canonical `scripts/check` path does not run the workflow's staging step. | M7-030 adds a fail-closed prerequisite that fetches the pinned asset and verifies its digest, or keeps the artifact-required suite behind an explicit mandatory gate with a clear fixture prerequisite. | The exact 2,499,451-byte asset has SHA-256 `c0988f62eb657c465a928825573e41e2eb2675241240312bc2228482cbafc9ee`. Restoring those bytes made the 16 release tests pass in scratch. Never regenerate or fabricate the artifact or weaken its digest. |
| M12-002 platform evidence (1 failure) | Three recorded `support_sources` digests are stale: `tools/m11_004_installed_consumers.py` (`05daa6700304` vs `fbaff2577108`), `tools/m11_003_native_websocket.py` (`b5eee3937bea` vs `7283af0b4af2`), and `tools/m7_021_linux_release.py` (`f1ffead25b5b` vs `59e1736cb7ba`). Validation therefore rejects the old platform report before the SDK-closure mutation assertion. | M12-002 re-captures and reseals native platform evidence against current support sources. | Do not change the validator order, narrow `SUPPORT_FILES`, or hand-edit source digests. |
| M7 task graph (current run: PASS) | The current status rows carry the expected issue links and classify M10-002 and M12-002 as BLOCKED while dependencies are incomplete. | The status-edge correction is included in the local #216 follow-up; `python3 -m unittest tools.tests.test_m7_linux_task_graph -v` passes all 6 tests. | The current `scripts/check` result contains no task-graph failure. This correction does not clear repository-wide dependency validation or make M10-002 COMPLETE. |

The independent 122-test analysis also confirmed that refreshing only the advisory timestamp is insufficient: retained M0-016/M3-031 security-update records and Windows provider-license raw-byte hashes need owner-generated evidence. It found a separate stale M3-031 hosted-run source map, which the targeted unit fixtures do not detect.

## M10-002 task-gate blockers

The current selected-task check records exit 2, `INVALID`, `commands: []`, and `DEPENDENCY_INCOMPLETE: M10-002 dependency is not COMPLETE: M9-001`. M9-001 remains BLOCKED because P1-015 is BLOCKED. The P1-012 scope fix from #220 is included in the local #216 ancestry; this check reaches M9-001 rather than stopping on the former plan-only prerequisite mismatch.

Repository-wide `validate-tasks` remains `INVALID` (exit 2) at `M10-001 dependency is not COMPLETE: M9-001`; it returns no task IDs. The current task-specific and repository-wide reports are `task-check-current.json` and `validate-tasks-current.json`.

The related status edges are corrected without completing blocked tasks: M9-001/002/003, M10-001/002, M10-005, M11-002/003, and M12-002 are BLOCKED where their dependencies or evidence are incomplete; required issue links are present. M10-003 / #175 remains BLOCKED and unchanged.

The strict repository validator evaluates declared dependencies even for BLOCKED rows. The corrected status graph test passes, but it does not establish global readiness or M10-002 acceptance. Do not change owner evidence or relax dependency validators to manufacture a pass.

These reports remain separate because they are bound to different candidate workspaces and dependency edges.

## Disposition

M10-002 remains **BLOCKED**. On source revision `e7c4bba5faf568317edd580e26eef118cc59057d`, architecture guard, `cjpm check`, `cjpm build`, strict docs (1,873/1,873 symbols and 950/950 parameters), and four HTTP/2 resource profiles (219/219 each) pass. The full native suite fails in two runs on different tests; both isolated replays pass but do not replace the full-suite gate. `scripts/check` exits 1 (584 tests: 24 failures, 16 errors, 4 skipped), with failures owned by M0-016, M3-031, M7-030, and M12-002. The current task gate is INVALID before acceptance commands because M9-001 is BLOCKED. Native network qualification is NOT_RUN.

Keep PR #216 **OPEN and DRAFT** and issue #174 open. Do not start or modify M10-003 / #175, and do not mark any PR ready or merge it. Refresh #216's description with these current-source outcomes; reevaluate readiness only after the direct task dependency and all acceptance gates pass on the exact candidate.

