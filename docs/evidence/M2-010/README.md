# M2-010 Linux connection route evidence

- Task: `M2-010`
- Profile: Linux x86_64 glibc
- Result: **PASS**
- Date: 2026-08-27, UTC+8
- Compiler: Cangjie `1.1.0-alpha.20260817040003`, `cjnative`
- Target: `x86_64-unknown-linux-gnu`

## Scope

M2-010 adds an immutable, proxy-ready connection route model without selecting
or discovering a system proxy. A route retains the origin separately from the
TCP connect target, explicitly records whether each name is resolved locally,
by the selected proxy, or is already a typed IP endpoint, and carries bounded
network-binding, TLS-context and ALPN parameters for later stages.

The M2-002 dependency is present in `src/internal/resolver/package.cj` and its
three contract tests in `src/internal/resolver/resolver_test.cj`: results retain
all normalized addresses and diagnostics, family filters are explicit,
pre-cancellation is honored, and absent TTL is not invented.

## Control-flow paths

| Path | Condition | Observable result |
|---|---|---|
| P001 | direct route with local name or typed IP | origin is also the connect target |
| P002 | explicit HTTP proxy route | proxy is the connect target while origin identity remains separate |
| P003 | locally resolved name | route target owns exactly one selected `Resolver` |
| P004 | proxy-resolved origin name | target has no local resolver and is valid only behind an explicit proxy |
| P005 | typed IP endpoint | target is marked resolved and can never enter DNS |
| P006 | direct remote-DNS origin or remote-DNS proxy target | construction throws `IllegalArgumentException` |
| P007 | network/TLS/ALPN identity exceeds its bound or contains invalid data | construction throws |
| P008 | caller mutates ALPN input or returned array | retained TLS parameters remain unchanged |

## Scenario and test matrix

| Scenario | Paths | Test |
|---|---|---|
| direct local DNS | P001,P003 | `directRouteRetainsItsLocalOriginResolver` |
| explicit proxy with remote origin DNS | P002,P003,P004 | `explicitProxySeparatesOriginAndProxyDns` |
| already-resolved direct/proxy endpoints | P001,P002,P005 | `typedIpTargetsNeverCarryResolvers` |
| invalid delegation and zero connect ports | P006 | `rejectsDelegatedDnsWithoutAnOwningProxyAndInvalidConnectTargets` |
| bounded, owned route metadata | P007,P008 | `networkAndTlsParametersAreBoundedAndOwned` |

## Acceptance decision

| Criterion | Evidence | Result |
|---|---|---|
| direct and explicit-proxy routes are distinct | P001/P002 and focused tests | PASS |
| origin DNS and proxy DNS ownership are explicit | P003 through P006 | PASS |
| network binding participates in route identity | bounded `NetworkBinding` with structural equality/hash tests | PASS |
| later TLS and ALPN parameters are retained safely | P007/P008, including exact 4096-byte ALPN boundary | PASS |
| no system-proxy implementation is introduced | only explicit `httpProxy` construction exists | PASS |
| architecture dependency direction is preserved | architecture guard reports PASS; no `std.net` import | PASS |

The backlog cross-reference `CONN-005` describes loser-candidate cleanup rather
than the route model. That invariant remains covered by M2-014; this task's
route acceptance follows its own backlog text, PRD 15.2/15.5 and threat-model
control `C-DNS` without weakening either requirement.

## Commands and results

Focused test command:

```text
env DISABLE_ZOXIDE=1 /home/elliot/.codex/scripts/codex_cangjie_env --cwd /home/elliot/playground/Wirestack cjpm test '--filter=ConnectionRouteTest.*' --no-color --no-progress
```

Result: exit 0 in the authorized environment; all five selected cases passed,
507 unrelated cases were skipped. The restricted runner first failed before
test execution because `std.unittest` could not create its local control socket
(`Operation not permitted`); product code was not changed for that harness limit.

Architecture guard:

```text
python3 tools/architecture_guard.py --root . --format text
```

Result: exit 0, `architecture guard: PASS`.

Canonical repository gate:

```text
env DISABLE_ZOXIDE=1 /home/elliot/.codex/scripts/codex_cangjie_env --cwd /home/elliot/playground/Wirestack ./scripts/check
```

Result: exit 0. All 50 repository-validator tests, 84 gate/tool tests and
8 benchmark-helper tests passed; the architecture guard passed; `cjpm check`
and `cjpm build` succeeded; all 512 Cangjie tests passed with zero skipped,
errors or failures. The build retained two unrelated unused-function warnings
in the transport adapter and HTTP/1 connection pool.

## Compatibility

This greenfield task adds declarations in the internal connector package and
does not alter existing declarations or behavior. The compatibility diff tool
reported `compatible`, but returned an empty file set because both production
and test files are new and untracked; therefore that parser result is treated
as an inventory blind spot, not as proof. Source compatibility is additive;
ABI and forward compatibility are not claimed for this internal, pre-release
package. Semantic compatibility is preserved because no existing route API
existed.

## Remaining boundary

This task models route intent only. It does not discover system proxies, open
connections, issue CONNECT, execute TLS/ALPN, or replace the later HTTP pool
key. Native Linux resolver backend work remains blocked by M2-003/UP-007.
