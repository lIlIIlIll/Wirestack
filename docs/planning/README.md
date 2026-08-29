# Planning and status

Wirestack separates product requirements, task definitions and execution state.

- [PRD](../product/prd.md): product scope and hard constraints.
- [Accepted ADRs](../architecture/README.md): reviewed implementation decisions.
- [Implementation backlog](implementation-backlog.md): task dependencies and
  acceptance criteria.
- [Global status](status.md): six-platform task state.
- [Linux status](linux-status.md): Linux x86_64 glibc delivery profile.

The Linux profile can complete independently under ADR-0002, but it does not
turn missing Windows or mobile evidence into a global pass. Linux musl remains
deferred by ADR-0004. Runtime/std improvements remain optional under ADR-0005.

Machine-readable task contracts live in `tools/tasks/`. A `COMPLETE` status
requires durable evidence; `BLOCKED`, `SKIPPED`, cross-compilation and stale
reports do not satisfy acceptance.

Older execution notes in this directory explain decisions at their recorded
time. Read the current status tables before using an old note as an action list.
