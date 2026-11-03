# Historical P1-012 receipts

Nothing in this directory is current evidence. Each file is retained so the
original tool output stays inspectable; the current P1-012 records are the
BLOCKED [`../evidence.json`](../evidence.json),
[`../global-readiness.json`](../global-readiness.json), and
[`../task-check.json`](../task-check.json).

## `validate-tasks-c1d908a5.json`

Byte-exact output of

```shell
python3 tools/repository/repository_tooling.py --root . validate-tasks --json --output docs/evidence/P1-012/historical/validate-tasks-c1d908a5.json
```

executed at `c1d908a5d1f3a53f8b6e038cc0eacd2bb1e9e50a`, the first revision of
this branch. It records PASS for 41 task IDs.

That PASS cannot recur at the final revision, but not because P1-012's own row
changed. At `c1d908a5` `validate-tasks` called the repository validator without
a requested task, and that revision checked dependency completeness only inside
the `requested is not None` branch. No status row therefore gated the global
run, which is consistent with the retained PASS over the 41 manifests present
at that revision. `M10-004` itself is `COMPLETE` at `c1d908a5`, at
`origin/main` (`d496a242`), and at this branch's head, but that is not what the
historical run tested.

The current validator applies the completeness check across the whole manifest
graph. At this branch's head `M10-004` is still `COMPLETE`, yet its dependency
`M10-003` is `BLOCKED`, so the `M10-004 -> M10-003` edge already fails. The
non-recurrence therefore comes from the new global status check plus every
failing edge below, not from P1-012's reclassification alone.

Repository-wide validation is strict over the whole manifest graph
regardless of any supplied task ID, so at head it rejects on seven dependency
edges rather than one:

| Dependent | Dependency | Dependency status at head |
|---|---|---|
| `M10-004` | `M10-003` | BLOCKED |
| `M11-001` | `M10-003` | BLOCKED |
| `M11-002` | `M10-003` | BLOCKED |
| `M11-004` | `M10-003` | BLOCKED |
| `M11-004` | `M11-001` | BLOCKED |
| `P1-013` | `P1-012` | BLOCKED |
| `P1-014` | `P1-012` | BLOCKED |

Completing `M10-003` alone therefore leaves three edges failing, not zero:
`M11-004 -> M11-001`, `P1-013 -> P1-012`, and `P1-014 -> P1-012`. Every row
that some manifest depends on must be `COMPLETE` before a repository-wide
PASS can recur. Exactly three such rows are not `COMPLETE` at head:
`M10-003` (BLOCKED), `M11-001` (BLOCKED), and `P1-012` (BLOCKED — this
branch's own recorded state, which only P1-012's real acceptance can change).
`M12-002` and `M12-003` are `IN_PROGRESS` and `BLOCKED` respectively but no
manifest lists them as a dependency, so they do not gate global validation.

Regenerate a current receipt only after those three rows are `COMPLETE` and
their evidence is bound:

```shell
python3 tools/repository/repository_tooling.py --root . validate-tasks --json --output docs/evidence/P1-012/validate-tasks-current.json
```

The retained copy never stands in for that run.

## `test-results-3ce15179.md`

The P1-012 results table written at `3ce15179` when P1-012 was first built. It
records 18 paths, 12 scenarios, 10 tests, `check-full` PASS, and
`verify-evidence P1-012` PASS. All four are historical: the current plan
validates as 19 paths, 18 scenarios, 16 tests
([`../test-plan-validation.json`](../test-plan-validation.json)), the current
repository-wide full check is INVALID before delegating to `scripts/check`
([`../full-check-current.json`](../full-check-current.json)), and the current
selected-task freshness result is FAIL with `ACCEPTANCE_NOT_PASS`
([`../evidence-task-current.json`](../evidence-task-current.json)). The
original file is preserved unedited; it is not a current report.

## `freshness-3ce15179.json`

A `verify-evidence P1-012` PASS captured at `3ce15179`, before this branch
reclassified P1-012 as BLOCKED. It is retained unedited as history and is
contradicted by the current
[`../evidence-task-current.json`](../evidence-task-current.json), which fails
on `ACCEPTANCE_NOT_PASS`. It was never referenced by an acceptance command or
by the evidence index; the current freshness result is the one above.
