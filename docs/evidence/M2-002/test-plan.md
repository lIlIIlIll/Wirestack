# M2-002 Resolver contract test plan

## Control-flow paths

| Path | Contract path |
|---|---|
| P001 | A result owns, deduplicates and returns all typed address candidates in stable order. |
| P002 | Canonical host, source and diagnostics remain observable without inventing expiration. |
| P003 | Family and maximum-result options filter a static result within explicit bounds. |
| P004 | Missing host and empty requested family return stable structured resolver errors. |
| P005 | Pre-cancellation and an expired Deadline terminate before resolver work. |
| P006 | Invalid result limits and diagnostics are rejected at construction. |

## Semantics

| Scenario | Paths | Expected public behavior |
|---|---|---|
| S001 | P001,P002 | Public `ResolveResult` owns the caller input, removes duplicates, preserves IPv6/IPv4 candidates, and leaves expiration absent. |
| S002 | P003 | Public `StaticResolver` applies family and result-count limits without changing the source result. |
| S003 | P004 | Public `ResolveException` retains resolve category, DNS phase, stable code, retryability and optional native-code fields. |
| S004 | P005 | Public `OperationContext` cancellation and Deadline inputs map to distinct resolver codes. |
| S005 | P006 | Public constructors reject zero or excessive result limits and inconsistent diagnostics. |

## Test-plan matrix

| Test | Scenarios | Test case |
|---|---|---|
| T001 | S001 | `resultOwnsAllTypedCandidatesWithoutInventingTtl` |
| T002 | S002 | `staticResolverAppliesFamilyAndResultBounds` |
| T003 | S003 | `errorsRetainStablePublicCoordinates` |
| T004 | S004 | `cancellationAndDeadlineRemainDistinct` |
| T005 | S005 | `constructorsRejectInvalidBoundsAndDiagnostics` |

## Gates

- Run the plan validator before implementation.
- Run the five focused public-owner tests.
- Run the architecture guard.
- Run the canonical `scripts/check` gate.
- Do not run long profiles or platform-native gates; M2-002 is a provider-neutral contract task.
