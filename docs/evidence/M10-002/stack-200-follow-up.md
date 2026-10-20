# M10-002 current-source acceptance follow-up

This report records the current PR #216 candidate, including Q4 outbound HTTP/2 DATA admission. It supersedes the earlier Stack #200 follow-up results for this candidate. The historical report at `docs/evidence/M10-002/verification.json` remains unchanged and is not evidence for this source revision.

## Candidate and scope

- Source revision: `7915e84f89182eac40e0f361fcf4c58b8818732e` (M10-002 source, tests, and manifest; review fixes are included).
- Platform: Linux x86_64 glibc.
- Toolchain: Cangjie 1.1.3, CJPM 1.1.3, cjdoc 0.7.2.
- Q4 behavior: slice each outbound DATA payload to one feasible frame before waiting for its exact managed-buffer lease; obtain that lease before flow-control credit; release it before blocking on flow credit; after a permit is granted, probe buffer capacity without blocking and retry if capacity or credit changed. Buffer-lease waits link caller cancellation with stream/controller termination. Reserve queue capacity before payload allocation and roll back admission state on rejection. Client DATA, duplex writes, normal server responses, and pushed responses use this path. Server response staging advances only after successful admission. Classic CONNECT without `:scheme` uses the actual HTTP/HTTPS transport scheme for resource ownership.
- No public API was added or changed.

Commit `7915e84f89182eac40e0f361fcf4c58b8818732e` contains the source and regression fixes for the current candidate. Evidence is bound to this code revision; no M10-003 or downstream task-manifest changes are included.

The full revision-bound results are in `docs/evidence/M10-002/stack-200-review/verification.json`; scenario coverage is in `scenario-matrix.json`. The strict generated-doc report is `docs-report.json`.

## Current acceptance results

| Gate | Result |
|---|---|
| `python3 tools/architecture_guard.py --root . --format text` | Exit 0; PASS. |
| `python3 tools/check_network_capabilities.py --check` | Exit 0; static contract PASS. Native capability execution was not run by this check. |
| `cjpm check` | Exit 0; PASS. |
| `cjpm build` | Exit 0; PASS; compiler emitted unreachable-block warnings, no build errors. |
| `cjpm test --exclude-tags=Performance --parallel 1 --no-progress --no-color` | Final run exit 0; 1,076 passed, 28 skipped, 0 errors, 0 failures (1,104 total). |
| HTTP/2 resource profiles | Each passed 213/213 with no skips/errors/failures: `RLIMIT_NOFILE=64`, `RLIMIT_DATA=1 GiB`, `RLIMIT_AS=4 GiB`, and CPU affinity 0. These used the task-manifest runtime-only `--skip-build` commands with the default heap. |
| `cjHeapSize=1GB scripts/check-docs --json --output docs/evidence/M10-002/stack-200-review/docs-report.json` | Exit 0; strict docs PASS; report covers 1,873/1,873 API symbols and 950/950 parameters across seven layers. The generated docs hash is `5cc77ecbb5432b68e71062e41a8744341f859ca19d43fb2179ff020044b3a099`; its pretty-serialized `docs.json` output was restored to the checked-in compact canonical file (SHA-256 `1fde2a6cc279ae78347a2013f698fc97303c41e5400e5825a871f0834e1b86c1`). |
| GitHub runs [39400213874](https://github.com/lIlIIlIll/Wirestack/actions/runs/39400213874) (`Clean Cangjie Build`) and [39400212565](https://github.com/lIlIIlIll/Wirestack/actions/runs/39400212565) (`M7-033 Developer Documentation`) at `3638eb49be6b4dad3ef018ec3c6d4440ee0ceee1` | Historical PASS on the previously published source only. No current-source GitHub Actions run has completed for `7915e84f89182eac40e0f361fcf4c58b8818732e`. |
| `scripts/check` | Re-run on source revision `7915e84f89182eac40e0f361fcf4c58b8818732e`; exit 1 in initial tooling unittest stage: 584 tests, 25 failures, 16 errors, 4 skipped. Failure families: stale AWS-LC advisory disposition, M3-031 provider fixtures/error codes, M7-030 release/evidence digests, M12-002 platform-support source, and M7 task-graph expectations. Separate Cangjie, resource-profile, and docs checks pass. |
| `python3 tools/repository/repository_tooling.py --root . check task M10-002 --json` | Exit 2; INVALID with `DEPENDENCY_INCOMPLETE`: current first finding is downstream M10-003 depending on BLOCKED M10-002. M10-002 itself declares COMPLETE M9-001. The checker validates every task manifest; M10-004 is also marked COMPLETE while M10-003 remains BLOCKED. Neither #175 nor M10-004 was modified. |

The earlier clean-build run `39393344922` failed at source-tree mutation rejection because pretty-printed `docs.json` differed from pinned CI CJDoc compact output. Commit `3638eb49be6b4dad3ef018ec3c6d4440ee0ceee1` fixed that historical revision, and run `39400213874` passed there. Both GitHub runs are pre-review-fix and are not evidence for the current source commit.

An earlier full-suite attempt in this acceptance sequence had one timeout in `Http2ConnectionPoolTest.saturatedCrossOriginWaiterDrainsHttp2ConnectionBeforeSameKeyRefill`; the isolated case passed 1/1, and the final full native run passed. This pool-fairness case is outside the Q4 changes and remains an observed stability risk, not an unconditional pass.

A noncanonical data-limit attempt with an extra `cjHeapSize=1GB` override exited 134 before tests because the runtime allocator could not create a page. The task-manifest-equivalent profile with default heap passed 213/213; only that result is counted above.

An intermediate full run before correcting newly added scheduler test budgets exited 1 with 1,073 passed, 28 skipped, and three errors. Those tests exhausted their reserved inbound-window budget; the test limits were corrected, and the final full run passed 1,076 with zero errors.

## Status and boundaries

M10-002 remains **BLOCKED** until the repository-wide `scripts/check` and global task-graph gate are clear. PR #216 remains open and draft; it must not be marked ready from the passing Q4-specific and native gates alone. Issue #174 remains open and untouched. M10-003 / issue #175 was not started or modified. No platform other than Linux x86_64 glibc is claimed.
