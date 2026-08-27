# M7-018 Linux M7 task graph evidence

## Status

- Task: `M7-018`
- Status: `COMPLETE`
- Platform: Linux x86_64 glibc
- Date: 2026-08-28, UTC+8
- Compiler: Cangjie `1.1.0-alpha.20260817040003`, `cjnative`
- Target: `x86_64-unknown-linux-gnu`

This task freezes the remaining Linux stable-release work. It does not mark a
release gate as passed. It also does not change the six-platform M7-001 through
M7-017 tasks.

## Dependency decision

ADR-0002 allows Linux to proceed after its Linux dependencies pass. ADR-0004
sets the current Linux target to native glibc x86_64. ADR-0005 makes runtime and
`std.net` source changes optional future improvements.

The task graph starts from these completed Linux tasks:

| Dependency | Retained result |
|---|---|
| M1-025 | Transport benchmark, cancellation P99, cleanup and soak pass |
| M2-016 | DNS-to-connected Linux benchmark passes |
| M3-028 | Linux TLS qualification passes |
| M5-030 | Linux HTTP/1 benchmark and examples pass |
| M6-025 | HTTP/2 facade concurrency and process termination pass |

No Linux M7 task depends on M1-026, M4, an `UP-*` task, or a runtime or
`std.net` source change.

## Frozen task graph

```text
M7-018
  +-> M7-019 -> M7-020 -> M7-021 -> M7-022
  |      |                    +----> M7-025
  |      +-> M7-026 -> M7-027
  +-> M7-023 ----------------------+
  +-> M7-024 ----------------------+
                                    v
                     M7-028 -> M7-029 -> M7-030
                         all M7-019..M7-030 -> M7-031
```

M7-019 is the main next step because it proves which P0 and release criteria
apply to Linux. M7-023 and M7-024 may proceed independently on separate
branches.

## Coverage

| Linux release requirement | Owner |
|---|---|
| P0, 15 lifecycle invariants and 22 release criteria | M7-019 |
| architecture, public API boundary and private ABI | M7-020 |
| release artifact, dependency scan and clean installation | M7-021 |
| final 24-hour mixed soak and resource bounds | M7-022 |
| ten fuzz targets, thresholds and crash replay | M7-023 |
| versioned performance baselines and automatic decisions | M7-024 |
| SBOM, provider manifest and build fingerprint | M7-025 |
| public API baseline and compatibility | M7-026 |
| migration guide and clean-consumer examples | M7-027 |
| security review package | M7-028 |
| independent security review and fix closure | M7-029 |
| artifact signing, verification, upgrade and rollback | M7-030 |
| final Linux acceptance matrix and release candidate | M7-031 |

## Scope boundary

M7-018 only defines the task graph and its evidence rules. It does not build an
artifact, rerun the 24-hour soak, claim security review completion, freeze the
API, or publish a release. Those claims remain blocked until their task-specific
evidence exists.

Linux musl remains outside the current profile until P1-011's SDK trigger is
satisfied. Non-Linux PRD criteria remain
`NOT_APPLICABLE_TO_LINUX_PROFILE`; they are not global PASS results.

## Verification

The repository test checks the exact task set, dependency boundary, status and
release-candidate fail-closed rule:

```text
python3 -m unittest tools.tests.test_m7_linux_task_graph -v
```

Result: exit `0`; 6/6 tests passed. The tests require exactly M7-018 through
M7-031, verify all published task counts, reject global or upstream blockers,
and keep the final candidate report fail-closed.

The existing fleet parser also accepts the new task rows and dependency ranges:

```text
python3 -m unittest tools.tests.test_codex_fleet -v
```

Result: exit `0`; 5/5 tests passed. A direct parse found 195 milestone tasks and
the exact 14-task Linux set M7-018 through M7-031.

The canonical repository gate is:

```text
/home/elliot/.codex/scripts/codex_cangjie_env scripts/check
```

Result: exit `0`.

- Repository-tool tests: 63/63 passed.
- Gate tests: 118/118 passed.
- Benchmark-tool tests: 23/23 passed.
- Architecture guard: `PASS`.
- `cjpm check`: passed.
- `cjpm build`: passed.
- Cangjie tests: 574 total, 552 passed, 22 Performance-tagged cases skipped,
  zero failures and zero errors.

Compilation retained four unused internal diagnostic-function warnings from
existing source. M7-018 changes no Cangjie source and adds no compiler warning.
