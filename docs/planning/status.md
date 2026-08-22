# Wirestack Implementation Status

This file is the lightweight execution index. The PRD and backlog remain the
sources of truth for scope, dependencies, and acceptance criteria.

Status values:

- `READY`: dependencies satisfied; task may start.
- `IN_PROGRESS`: exactly one active implementation branch/PR owns the task.
- `BLOCKED`: dependency, gate, platform, upstream, or evidence requirement is missing.
- `COMPLETE`: all acceptance criteria are satisfied and durable evidence is linked.

## Repository bootstrap

| ID | Status | Evidence | Notes |
|---|---|---|---|
| BOOTSTRAP-001 | COMPLETE | [`docs/evidence/BOOTSTRAP-001/README.md`](../evidence/BOOTSTRAP-001/README.md) | Initialized Wirestack product/planning/architecture/gate/evidence control plane; no production network implementation. |

## M0

| ID | Status | Evidence | Notes |
|---|---|---|---|
| M0-001 | COMPLETE | [`docs/evidence/M0-001/README.md`](../evidence/M0-001/README.md) | SDK/source inventory and delete/reuse/isolate decisions complete; no runtime gate implied. |
| M0-002 | READY | — | M0-001 complete; freeze the actual CJPM package/directory mapping using the supplied SDK. |
| M0-003 | BLOCKED | — | Depends on M0-002. |
| M0-004 | READY | — | M0-001 complete; establish the gate harness and result schema. |
| M0-005 | BLOCKED | — | Depends on M0-004. |
| M0-006..M0-022 | BLOCKED | — | Follow the dependency graph in `implementation-backlog.md`. |

## Conditional upstream work

`UP-001` through `UP-007` are all **BLOCKED / DO NOT START** until the corresponding
M0 gate failure provides reproducible evidence and a minimal upstream-interface RFC.

Actual `std.net`/runtime source changes belong in their upstream repositories,
not in the Wirestack worktree.

## Later milestones

M1 through M7 and P1 tasks are blocked by their backlog dependencies. Do not
mark them READY merely because preparatory code could be written early.
