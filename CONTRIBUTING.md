# Contributing to Wirestack

Wirestack uses evidence-backed, one-task changes. Read `AGENTS.md`, the PRD,
all accepted ADRs, the backlog entry and current status before editing.

## Choose one task

Each implementation branch and pull request owns exactly one backlog task ID.
Verify that every dependency is `COMPLETE` and has durable evidence. If no task
covers the work, add an independent task contract first. Do not weaken a gate to
mark a blocked task complete.

Use GitButler for branch, diff, commit, push and history operations. Preserve
unrelated changes and use a dedicated branch for the task.

## Keep the architecture boundary

```text
HTTP → TLS → Transport SPI ← StdNetTransport → std.net
```

Only `wirestack.internal.transport_stdnet` may import `std.net`. Do not expose
provider-native or `std.net` types, call private `CJ_MRT_Sock*` symbols, add a
second timeout owner, parse exception messages as control flow, or introduce an
unbounded collection.

Runtime, std, stdx and SDK repositories are read-only references from a
Wirestack task. Wirestack release work uses public SDK capabilities; future
upstream improvements are not release dependencies.

## Write the test plan first

Create `docs/evidence/<TASK-ID>/test-plan.md` with Pxxx paths, Sxxx scenarios and
Txxx tests, then validate it:

```bash
python3 tools/repository/repository_tooling.py \
  --root . validate-plan docs/evidence/<TASK-ID>/test-plan.md --json
```

Add `tools/tasks/<TASK-ID>.json` with dependencies, allowed paths, platforms,
acceptance commands, evidence, timeouts, long-gate metadata and source paths.

## Run the right validation layer

```bash
scripts/check-fast --json
scripts/check-task <TASK-ID> --json
scripts/check-full --json
scripts/check-long <TASK-ID> --json
```

Only `scripts/check-long` may select a command marked long. Never place a
one-hour SSE profile, 24-hour soak or other long test in fast/full validation.
`scripts/check` remains the compatibility entry point. Do not build the SDK for
a Wirestack contribution.

## Record evidence honestly

Store durable evidence under `docs/evidence/<TASK-ID>/`, then verify freshness:

```bash
scripts/verify-evidence <TASK-ID> --json
```

`SKIPPED`, `BLOCKED`, cross-compilation, a short preflight and stale source
digests are not passes. Platform claims require native hardware or a native VM.

## Documentation and review

Update each affected reader path and run `scripts/check-docs --json`. Preserve
accepted decisions and historical evidence. Keep implementation and its tests
together; split unrelated work. Do not commit, push or create a pull request
unless the current request authorizes it.
