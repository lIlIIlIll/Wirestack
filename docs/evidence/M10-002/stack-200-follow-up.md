# M10-002 current-source acceptance follow-up

This report records the current PR #216 candidate, including Q4 outbound HTTP/2 DATA admission. It supersedes the earlier Stack #200 follow-up results for this candidate. The historical report at `docs/evidence/M10-002/verification.json` remains unchanged and is not evidence for this source revision.

## Candidate and scope

- Source revision: `3638eb49be6b4dad3ef018ec3c6d4440ee0ceee1` (`docs: match pinned CI API output`; includes Q4 implementation commit `f05ee90d1f32dce35c6cd5b9799001d9d1f19233`).
- Platform: Linux x86_64 glibc.
- Toolchain: Cangjie 1.1.3, CJPM 1.1.3, cjdoc 0.7.2.
- Q4 behavior: obtain the exact managed-buffer lease before trying flow-control credit; release the lease before blocking on flow credit; after a permit is granted, probe buffer capacity without blocking and retry if capacity or credit changed. Reserve queue capacity before payload allocation and roll back admission state on rejection. Client DATA, duplex writes, normal server responses, and pushed responses use this path. Server response staging advances only after successful admission.
- No public API was added or changed.

The candidate follow-up commit changes only `docs/api/generated/docs.json` serialization to the pinned CI CJDoc output. Production source and tests remain identical to the tested implementation commit `f05ee90d1f32dce35c6cd5b9799001d9d1f19233`.

The full revision-bound results are in `docs/evidence/M10-002/stack-200-review/verification.json`; scenario coverage is in `scenario-matrix.json`. The strict generated-doc report is `docs-report.json`.

## Current acceptance results

| Gate | Result |
|---|---|
| `python3 tools/architecture_guard.py --root . --format text` | Exit 0; PASS. |
| `python3 tools/check_network_capabilities.py --check` | Exit 0; static contract PASS. Native capability execution was not run by this check. |
| `cjpm check` | Exit 0; PASS. |
| `cjpm build` | Exit 0; PASS; compiler emitted unreachable-block warnings, no build errors. |
| `cjpm test --exclude-tags=Performance --parallel 1 --no-progress --no-color` | Final run exit 0; 1,071 passed, 28 skipped, 0 errors, 0 failures. |
| HTTP/2 resource profiles | Each passed 210/210 with no skips/errors/failures: `RLIMIT_NOFILE=64`, `RLIMIT_DATA=1 GiB`, `RLIMIT_AS=4 GiB`, and CPU affinity 0. These used the task-manifest runtime-only `--skip-build` commands with the default heap. |
| `scripts/check-docs` with pinned CI CJDoc 0.7.2 (run `39393344922` artifact) | Exit 0; strict docs PASS; 1,873/1,873 API symbols and 950/950 parameters covered; all seven package layers have full coverage. Canonical `docs.json` SHA-256: `1fde2a6cc279ae78347a2013f698fc97303c41e5400e5825a871f0834e1b86c1`. |
| GitHub `Clean Cangjie Build` run [39400213874](https://github.com/lIlIIlIll/Wirestack/actions/runs/39400213874) at `3638eb49be6b4dad3ef018ec3c6d4440ee0ceee1` | PASS; current-source build/test gate, installed public consumer, and source-tree mutation check all passed. |
| GitHub `M7-033 Developer Documentation` run [39400212565](https://github.com/lIlIIlIll/Wirestack/actions/runs/39400212565) at `3638eb49be6b4dad3ef018ec3c6d4440ee0ceee1` | PASS; strict documentation gate and public clean consumer passed. |
| `scripts/check` | Re-run on source revision `3638eb49be6b4dad3ef018ec3c6d4440ee0ceee1`; exit 1 in initial tooling unittest stage: 584 tests, 25 failures, 16 errors, 4 skipped. Failure families remain stale AWS-LC advisory disposition, M3-031 provider fixtures/error codes, M7-030 release/evidence digests, M12-002 platform-support source, and M7 task-graph expectations. Separate Cangjie and canonical docs checks pass. |
| `python3 tools/repository/repository_tooling.py --root . check task M10-002 --json` | Exit 2; INVALID with `DEPENDENCY_INCOMPLETE`: current first finding is downstream M10-003 depending on BLOCKED M10-002. M10-002 itself declares COMPLETE M9-001. The checker validates every task manifest; M10-004 is also marked COMPLETE while M10-003 remains BLOCKED. Neither #175 nor M10-004 was modified. |

The prior clean-build run `39393344922` failed only at source-tree mutation rejection: committed pretty-printed `docs.json` differed from pinned CI CJDoc's compact output. Commit `3638eb49be6b4dad3ef018ec3c6d4440ee0ceee1` normalizes that generated file; clean-build run `39400213874` passed the mutation gate.

One earlier full-suite run on this candidate had one timeout in `Http2ConnectionPoolTest.saturatedCrossOriginWaiterDrainsHttp2ConnectionBeforeSameKeyRefill`; the isolated case passed 1/1, and the latest full native run passed. This pool-fairness case is outside the Q4 changes and remains an observed stability risk, not an unconditional pass.

A noncanonical data-limit attempt with an extra `cjHeapSize=1GB` override exited 134 before tests because the runtime allocator could not create a page. The task-manifest-equivalent profile with default heap then passed 210/210; only that result is counted above.

## Status and boundaries

M10-002 remains **BLOCKED** until the repository-wide `scripts/check` and global task-graph gate are clear. PR #216 remains open and draft; it must not be marked ready from the passing Q4-specific and native gates alone. Issue #174 remains open and untouched. M10-003 / issue #175 was not started or modified. No platform other than Linux x86_64 glibc is claimed.
