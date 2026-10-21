# M10-002 repository and task-gate blocker analysis

## Evidence boundary

The M10-002 Q4 source revision is `e72bbb3c8a10670b716dcf263cdafff052102b84`. The existing targeted repository diagnostic is bound to candidate `b872f1b8304a16a769a517efa8cdf566e20ff963` and records 122 tests, 25 failures, 16 errors, and 0 skips. A read-only root-cause follow-up inspected candidate `8f7903125934962621ee27d328b68a0d2233972a` (tree `a2bd279d376f6f20e539697802f0f1cabbd5c3ec`). It made no retained source, evidence, or fixture changes.

The follow-up reproduced the same 122-test result. It also applied the four non-fabricating owner corrections only in memory or reverted scratch paths; that diagnostic then reported 122 tests passing. This is causal analysis, **not** a repository `scripts/check` pass, an M10-002 task-gate pass, or durable owner evidence. The scratch fixture was removed.

## Repository-wide check blockers

| Family | Confirmed root cause | Owning correction | Boundary |
|---|---|---|---|
| TLS provider validation (19 failures, 8 errors) | All three provider records retain `reviewed_through = 2026-08-31T17:30:00Z`; the 31-day advisory-intake expiry rejects validation before later negative and positive assertions run. | M0-016 performs the actual advisory review across the documented intake channels, updates provider disposition only with authoritative review evidence, then regenerates retained M0-016/M3-031 results. | Do not bump the date, IDs, or approval state without the security review. A disposition-only edit also leaves retained-result source-object and Windows license-byte digest mismatches. |
| M3-031 desktop evidence (4 failures, 2 errors) | The stale-advisory exception is mapped to `RAW_RESULT` before the intended `PLATFORM`, `LICENSE_BUNDLE`, and `STALE_REVISION` assertions; the exact-native-result cases fail at the same earlier validation. Separately, the on-disk hosted run is `STALE_SOURCE`: its recorded `run.py` / `validate.py` digests predate the current scripts. | M3-031 and M0-016 refresh the provider inputs, rerun the hosted desktop workflow, and retain new `hosted-run.json`, `provider-result.json`, and validation evidence. | The validation error mapping is not the root defect. The hosted-run digest gap is not covered by the current unit fixtures; its owner must add source-bound evidence checks. |
| M7-030 release/evidence (8 errors) | The suite reads `dist/m7-021/wirestack-0.1.0-linux-x86_64-glibc.tar.gz`, which is ignored and absent in a clean checkout. The artifact is available only from the frozen staging tag `m7-030-frozen-artifact-c0988f62`; the canonical `scripts/check` path does not run the workflow's staging step. | M7-030 adds a fail-closed prerequisite that fetches the pinned asset and verifies its digest, or keeps the artifact-required suite behind an explicit mandatory gate with a clear fixture prerequisite. | The exact 2,499,451-byte asset has SHA-256 `c0988f62eb657c465a928825573e41e2eb2675241240312bc2228482cbafc9ee`. Restoring those bytes made the 16 release tests pass in scratch. Never regenerate or fabricate the artifact or weaken its digest. |
| M12-002 platform evidence (1 failure) | Three recorded `support_sources` digests are stale: `tools/m11_004_installed_consumers.py` (`05daa6700304` vs `fbaff2577108`), `tools/m11_003_native_websocket.py` (`b5eee3937bea` vs `7283af0b4af2`), and `tools/m7_021_linux_release.py` (`f1ffead25b5b` vs `59e1736cb7ba`). Validation therefore rejects the old platform report before the SDK-closure mutation assertion. | M12-002 re-captures and reseals native platform evidence against current support sources. | Do not change the validator order, narrow `SUPPORT_FILES`, or hand-edit source digests. |
| M7 task graph (1 failure) | `status.md` says M10-004 is COMPLETE while M10-003 is BLOCKED; backlog and `tools/tasks/M10-004.json` both declare M10-003 as a dependency. The graph test correctly rejects that inconsistent row. | M10-004's owner corrects its status row to BLOCKED until its dependency and acceptance evidence are valid. | This status belongs to M10-004, not M10-002. An in-memory row correction clears the graph unit test only; it does not make the strict global task validator pass. |

The independent 122-test analysis also confirmed that refreshing only the advisory timestamp is insufficient: retained M0-016/M3-031 security-update records and Windows provider-license raw-byte hashes need owner-generated evidence. It found a separate stale M3-031 hosted-run source map, which the targeted unit fixtures do not detect.

## M10-002 task-gate blockers

`task-check-current.json` is `INVALID` (exit 2), has `commands: []`, and reports `DEPENDENCY_INCOMPLETE: P1-013 dependency is not COMPLETE: P1-012`. No M10-002 acceptance command ran.

P1-012's `global-readiness.json` is `BLOCKED`: the global readiness check rejects M10-004 because M10-003 is not COMPLETE. `validate-tasks` and global fast/full checks stop as `INVALID` before commands; evidence-all and task evidence verification fail. The planning status also contains the M10-004/M10-003 contradiction above.

The strict repository validator evaluates declared dependencies even for BLOCKED rows. Therefore changing only M10-004's row to BLOCKED repairs the graph unit test but does not clear global task readiness or the M10-002 closure. The scoped-readiness changes on draft PR #220 are not integrated into #216 and have not made P1-012 COMPLETE; the combined-workspace M10-002 gate still returns `INVALID` on the P1-012 dependency.

These are cross-task gate/status ownership issues. Do not edit M10-004, P1-012, or P1-013 evidence on the M10-002 branch, and do not relax the graph or dependency validators to manufacture a pass.

## Disposition

M10-002 remains **BLOCKED**. The Q4 source and its recorded Linux-focused checks are not a substitute for repository-wide or task-gate acceptance. The blocker fixes require evidence or status changes owned by M0-016, M3-031, M7-030, M12-002, M10-004, and P1-012; none is safely resolvable by changing M10-002's HTTP/2 implementation.

Keep PR #216 **OPEN and DRAFT** and issue #174 open. Do not start or modify M10-003 / #175, and do not mark any PR ready or merge it. Reevaluate #175 only after the repository checks and M10-002 task gate become valid and the required M10-002 acceptance commands pass on the exact candidate.
