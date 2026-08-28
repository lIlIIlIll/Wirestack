# M1-001 Linux Transport package evidence

## Status

- Task: `M1-001`
- Linux x86_64 glibc: **COMPLETE**
- Other platforms: **NOT RUN**

This task verifies the physical Transport Core, StdNet adapter, test, and
benchmark layout. It does not claim the global six-platform M1 exit gate.

## Dependency decision

Global M0-019 and M0-022 remain blocked by non-Linux platform evidence.
ADR-0002 permits Linux work once the matching Linux decisions and gates are
complete. ADR-0004 limits this profile to native glibc x86_64, and ADR-0005
keeps runtime and `std.net` source changes outside the release dependency graph.
This task does not change either global M0 status.

## Accepted physical layout

ADR-0001 and M0-002 freeze one static CJPM project with `src` as its source
root. The relevant packages are:

| Responsibility | Package | Path |
|---|---|---|
| Transport Core | `wirestack.internal.transport` | `src/internal/transport/` |
| public-SDK TCP adapter | `wirestack.internal.transport_stdnet` | `src/internal/transport_stdnet/` |
| Transport tests | matching package test files | `src/internal/transport/*_test.cj` and `src/internal/transport_stdnet/*_test.cj` |
| initial Transport benchmark harness | adapter benchmark test | `src/internal/transport_stdnet/benchmark_harness_test.cj` |

CJPM uses co-located `_test.cj` files for these package tests. The accepted
physical layout therefore replaces the backlog's earlier logical `tests/` and
`benchmarks/` sketch.

## Acceptance mapping

| Criterion | Evidence | Result |
|---|---|---|
| Transport Core package exists | `wirestack.internal.transport` contains the package anchor and core source files. | PASS |
| StdNet package exists | `wirestack.internal.transport_stdnet` contains the package implementation and imports `std.net` only inside the allowed adapter package. | PASS |
| Test layout exists | Both packages contain build-discovered `_test.cj` files; the current non-performance suite executes their tests. | PASS |
| Benchmark layout exists | `benchmark_harness_test.cj` supplies the original adapter benchmark entry, with later task-specific harnesses in the same package. | PASS |
| Internal boundary is enforced | ADR-0001 assigns internal roles. The architecture guard rejects `std.net` outside the adapter, private runtime ABI, legacy stdx network packages, and lower-level types in public APIs. | PASS |
| Default build does not select a legacy stack | `cjpm.toml` has no package dependency on legacy stdx TLS or HTTP. The repository is greenfield, so there is no legacy Wirestack implementation to select. | PASS |
| Canonical build accepts the package graph | `cjpm check`, `cjpm build`, and the architecture guard pass through `scripts/check`. | PASS |

## Commands and results

```bash
/home/elliot/.codex/scripts/codex_cangjie_env scripts/check
```

Result: exit status 0. The command passed 57 repository-tool tests, 114 gate-tool
tests, 23 benchmark-tool tests, the architecture guard, `cjpm check`, and
`cjpm build`. The non-performance Cangjie suite finished with 545 passed, 20
skipped, 0 failed, and 0 errors.

The active toolchain is Cangjie `1.1.0-alpha.20260817040003` with CJPM 1.1.3 on
`x86_64-unknown-linux-gnu`.

## Scope limits

- This task validates package and target structure. Later M1 tasks own behavior.
- No production source changed during this evidence closure.
- No runtime, std, or SDK source was modified.
- No SDK component was built.
