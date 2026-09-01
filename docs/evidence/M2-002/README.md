# M2-002 Resolver contract evidence

- Task: `M2-002`
- Result: **PASS**
- Date: 2026-08-31, UTC+8
- Validation host: Linux x86_64 glibc
- Compiler: Cangjie `1.1.0-alpha.20260829040003`, `cjnative`
- Target: `x86_64-unknown-linux-gnu`
- CJPM: `1.1.3`

## Scope

The provider-neutral public `wirestack` package owns `Resolver`,
`ResolveResult`, `ResolveOptions`, `ResolveDiagnostics`, `ResolveException` and
their enums. The contract contains no `std.net`, provider or native-handle
types. Results retain every distinct typed address candidate in stable order,
own their input and output arrays, preserve canonical host and source, and keep
expiration absent when a backend has no TTL.

`StaticResolver` proves the public contract independently of a platform DNS
backend. It applies explicit family and result-count bounds, observes the
canonical `OperationContext`, and maps missing data, cancellation and Deadline
expiration to stable structured errors.

No production declaration changed in this closure task. The missing work was
independent public-owner coverage and durable task evidence; the earlier
tests exercised aliases from `wirestack.internal.resolver`.

## Acceptance decision

| Criterion | Evidence | Result |
|---|---|---|
| Result contains all typed addresses and family identity | T001 imports the public `wirestack` owner as `api` and retains ordered IPv6 and IPv4 candidates | PASS |
| Canonical host, source and diagnostics are observable | T001 checks the public fields and duplicate count | PASS |
| No TTL is invented | T001 observes `expiration.isNone()` | PASS |
| Family and result bounds are explicit | T002 and T005 cover filtering plus 1..1024 limits | PASS |
| Errors have stable public coordinates | T003 checks resolve category, DNS phase, stable code, retryability and native-code absence | PASS |
| Cancellation and Deadline remain distinct | T004 observes `Cancelled` and `Timeout` separately | PASS |
| Public contract is independent of internal aliases | The focused suite imports root owner `wirestack` as `api` and uses only `api.*` resolver types instead of the internal aliases | PASS |

The P001-P006, S001-S005 and T001-T005 trace matrix is recorded in
[`test-plan.md`](test-plan.md).

## Commands and exact results

Plan validation:

```text
python3 tools/repository/repository_tooling.py validate-plan docs/evidence/M2-002/test-plan.md --json
```

Result: exit 0, `status=PASS`, 6 paths, 5 scenarios and 5 tests.

Focused public-contract tests:

```text
/home/elliot/.codex/scripts/codex_cangjie_env --cwd /home/elliot/playground/Wirestack cjpm test '--filter=M2002ResolverPublicContractTest.*' --no-progress --no-color
```

Result: exit 0. All 5 selected cases passed; 592 unrelated cases were skipped.
The compiler emitted pre-existing unittest macro expansion warnings in TLS
tests and one pre-existing unused import warning.

Architecture guard:

```text
python3 tools/architecture_guard.py --root . --format text
```

Result: exit 0, `architecture guard: PASS`.

Canonical repository gate:

```text
/home/elliot/.codex/scripts/codex_cangjie_env --cwd /home/elliot/playground/Wirestack ./scripts/check
```

Result: exit 0. The three Python suites passed 227, 144 and 24 tests;
architecture guard, `cjpm check` and `cjpm build` passed; the Cangjie suite
finished with 597 total, 574 passed, 23 repository-defined skips and zero
errors or failures. All five M2-002 cases executed and passed. The skipped
cases are not used as M2-002 evidence.

## Remaining boundary

M2-002 defines a platform-neutral contract; it does not claim a native DNS
backend on Windows, Apple or mobile platforms. M2-004 must validate the Windows
backend on a GitHub-hosted Windows runner. M2-006 must use GitHub-hosted macOS
for the macOS backend and may not claim iOS support without an allowed native
iOS execution environment.

No long profile, 86,400-second soak or non-Linux platform gate was run for this
contract-only task.
