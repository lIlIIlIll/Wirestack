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
| BOOTSTRAP-001 | COMPLETE | [`docs/evidence/BOOTSTRAP-001/README.md`](../evidence/BOOTSTRAP-001/README.md) | Initialized the repository control plane; no production network implementation. |

## M0

| ID | Status | Evidence | Notes |
|---|---|---|---|
| M0-001 | COMPLETE | [`docs/evidence/M0-001/README.md`](../evidence/M0-001/README.md) | SDK/source inventory and disposition decisions complete. |
| M0-002 | COMPLETE | [`docs/evidence/M0-002/README.md`](../evidence/M0-002/README.md) | CJPM package/path mapping frozen by ADR-0001. |
| M0-003 | COMPLETE | [`docs/evidence/M0-003/README.md`](../evidence/M0-003/README.md) | Architecture dependency guard and CI are active. |
| M0-004 | COMPLETE | [`docs/evidence/M0-004/README.md`](../evidence/M0-004/README.md) | Versioned gate runner and evidence framework complete. |
| M0-005 | COMPLETE | [`docs/evidence/M0-005/README.md`](../evidence/M0-005/README.md) | Existing Linux x86_64 `std.net` raw TCP baseline captured. |
| M0-006 | COMPLETE | [`docs/evidence/M0-006/README.md`](../evidence/M0-006/README.md) | Linux x86_64 close/wakeup probes pass locally; global six-platform GATE-NET-01 remains incomplete. |
| M0-007 | COMPLETE | [`docs/evidence/M0-007/README.md`](../evidence/M0-007/README.md) | Full duplex and 100 close races pass; same-direction behavior captured; public abort is unavailable, so Linux/global GATE-NET-02 remain incomplete. |
| M0-008 | READY | — | Execute absolute-deadline probes using M0-006/M0-007 evidence. |
| M0-009 | BLOCKED | — | Depends on M0-008 evidence. |
| M0-010 | READY | — | Linux large-buffer evidence may proceed independently; global GATE-NET-05 still needs Windows and future adapter comparison. |
| M0-011 | READY | — | Depends on M0-005 and M0-006 evidence. |
| M0-012 | BLOCKED | — | Depends on M0-011 evidence and native mobile runners. |
| M0-013 | BLOCKED | — | Follow the dependency graph in `implementation-backlog.md`. |
| M0-014 | BLOCKED | — | Requires a native Windows SDK/runner. |
| M0-015..M0-022 | BLOCKED | — | Follow the dependency graph in `implementation-backlog.md`. |

## Conditional upstream work

`UP-001` through `UP-007` remain **BLOCKED / DO NOT START** until the corresponding
failed gate provides reproducible evidence and an approved minimal upstream-interface RFC.
Actual `std.net`/runtime source changes belong in their upstream repositories,
not in the Wirestack worktree.

The M0-007 abort probe records that the supplied SDK has no public `TcpSocket.abort()`
member. This is evidence for later minimum-upstream analysis; it does not independently
authorize an upstream implementation task.

## Later milestones

M1 through M7 and P1 tasks remain blocked by their backlog dependencies. A Linux-only
M0 result must not be generalized to the six-platform release matrix.
