# M7-032 test plan

## Semantics

M7-032 gives each public, user-visible contract a public package owner. It
removes aliases and declaration references to `wirestack.internal.*` without
adding compatibility wrappers. Internal provider, protocol, native-handle, and
platform types stay internal.

The checked API inventory describes the resulting pre-1.0 API. It is not a
backward-compatibility comparison with the historical M7-026 baseline.

## Control-flow path matrix

| Path ID | Conditions and values | Runtime/compiler checks | Reachability | Notes |
|---|---|---|---|---|
| P001 | Public declaration is owned by `wirestack`, `wirestack.http`, or `wirestack.tls` | Package and declaration scan | Reachable | User-visible nominal identity is public. |
| P002 | Public declaration directly aliases an internal type | Architecture guard | Reachable error path | Must fail with a stable rule ID. |
| P003 | Public declaration exposes an internal type in a parameter, return, field, bound, or inheritance clause | Architecture guard | Reachable error path | Comments and string literals do not count. |
| P004 | Internal implementation imports a public contract | Dependency graph scan and build | Reachable | This is the required implementation direction. |
| P005 | Public and internal packages form a cycle | Dependency graph scan | Reachable error path | The gate fails before compilation. |
| P006 | Provider, protocol state, native handle, or platform adapter becomes public | Inventory allowlist and architecture scan | Reachable error path | Implementation details remain internal. |
| P007 | Clean consumer constructs, passes, matches, and catches public types | Native clean-consumer build and run | Reachable | No internal import is allowed. |
| P008 | Existing experimental public declaration changes or disappears | New inventory generation | Reachable | No compatibility verdict is required. |
| P009 | Final source differs from API, artifact, performance, or SBOM evidence | Evidence freshness gates | Reachable error path | Stale PASS is rejected. |
| P010 | Long-duration soak is selected by a non-long gate | Task contract validation | Reachable error path | M7-032 never starts the 24-hour soak. |

## Semantic scenario matrix

| Scenario ID | Input | Pre-state | Triggered path IDs | Expected behavior | Required assertions | Type | Priority |
|---|---|---|---|---|---|---|---|
| S001 | Public contract source | Ownership migration complete | P001,P004 | All user-visible contracts have public nominal owners | Public owner and allowed dependency direction asserted | architecture | P0 |
| S002 | Direct alias to `wirestack.internal.transport.Deadline` | Synthetic public package | P002 | Guard rejects the alias | Stable `public-internal-alias` violation | negative | P0 |
| S003 | Internal type in a public function or class header | Synthetic public package | P003 | Guard rejects every exposed position | Stable `public-internal-type` violation | negative | P0 |
| S004 | Public/internal import graph with a cycle | Synthetic source tree | P004,P005 | Gate rejects the cycle | Cycle members reported deterministically | negative,architecture | P0 |
| S005 | Provider and state-machine symbols | Production tree | P006 | Symbols are absent from public inventory | Exact forbidden-owner set is empty | architecture | P0 |
| S006 | Public-only Linux consumer | Current source and SDK | P007 | Consumer builds and runs | Construction, matching, catching, and transport use succeed | integration,platform | P0 |
| S007 | Historical M7-026 declarations differ | New inventory | P008 | Inventory is accepted as the new contract | No compatibility shim or verdict is produced | api | P0 |
| S008 | Mutated source after PASS evidence | Sealed reports | P009 | Evidence becomes STALE/FAIL | Source digest mismatch is explicit | evidence,negative | P0 |
| S009 | M7-032 task entry through fast/full gates | Valid manifest | P010 | No long command is selected | Every selected command has `long_running=false` | task-contract | P0 |

## Test-plan matrix

| Test ID | Scenario IDs | Path IDs | Input | Expected result | Assertions | Type |
|---|---|---|---|---|---|---|
| T001 | S001,S005,S007 | P001,P004,P006,P008 | Production source and API inventory | Static ownership gate PASS | Public owners, internal detail boundary, no compatibility artifacts | static |
| T002 | S002,S003 | P002,P003 | Fault-injected public declarations | Architecture guard FAIL | Stable rule IDs and exact source coordinates | fault-injection |
| T003 | S004 | P004,P005 | Synthetic cyclic import graph | Dependency gate FAIL | Deterministic cycle report | fault-injection |
| T004 | S006 | P007 | Temporary Linux consumer | Build and run PASS | No internal import; observable public behavior succeeds | integration |
| T005 | S008 | P009 | Sealed report plus source mutation | STALE/FAIL | Digest drift invalidates prior PASS | evidence |
| T006 | S009 | P010 | M7-032 manifest | Contract validation PASS | No long-running command in fast/task/full selection | static |

## Excluded gates

This task does not run the M7-022 86,400-second soak. The final release
candidate reruns that soak once after M7-029 and all source-sensitive artifact,
API inventory, performance, SBOM, and installation gates have been regenerated.

