# M2-001 Linux host and endpoint model evidence

- Task: `M2-001`
- Profile: Linux x86_64 glibc
- Result: **PASS**
- Date: 2026-08-27, UTC+8
- Compiler: Cangjie `1.1.0-alpha.20260817040003`, `cjnative`
- Target: `x86_64-unknown-linux-gnu`

## Scope

M2-001 closes the DNS-free host and endpoint value model. `HostName` owns one
canonical ASCII DNS name, removes at most one root dot, folds ASCII case and
checks the 63-byte label and 253-byte name limits. It accepts an already
encoded IDNA A-label such as `xn--bcher-kva` and rejects Unicode U-label input.

`IpAddress` separates IPv4 and IPv6 by family, owns an immutable octet snapshot
and permits a zone only on IPv6. `SocketEndpoint` pairs an already-resolved
address with a typed `UInt16` port. These constructors do no I/O and import no
network package, so they cannot trigger DNS.

M2 types do not parse an HTTP authority. Passing authority syntax to
`HostName`, including a port, userinfo, brackets, path, query or fragment,
fails. Full HTTP URL and authority parsing remains in the already separate
M5-002 implementation.

## Control-flow paths

| Path | Condition | Observable result |
|---|---|---|
| P001 | host input is empty | construction throws `IllegalArgumentException` |
| P002 | host has one trailing root dot and valid ASCII labels | root dot is removed and ASCII case is folded |
| P003 | canonical host is outside 1..253 bytes | construction throws |
| P004 | a label is outside 1..63 bytes or has an invalid edge/character | construction throws |
| P005 | IP octet count does not match its family, or IPv4 has a zone | construction throws |
| P006 | IPv6 zone is absent or contains 1..64 bytes | address retains the exact optional zone as identity |
| P007 | caller mutates input or returned octets | the address snapshot remains unchanged |
| P008 | endpoint receives any `UInt16` port | the port remains typed, including 0 and 65535 boundaries |

## Scenario and test matrix

| Scenario | Paths | Test | Required assertions |
|---|---|---|---|
| S001 canonical ASCII and A-label | P002,P004 | `canonicalizesAsciiCaseAndOneRootDot`; `acceptsAsciiALabelAndExactDnsLengthBoundaries` | lowercase identity, one root dot removed, A-label retained |
| S002 DNS length boundaries | P003,P004 | `acceptsAsciiALabelAndExactDnsLengthBoundaries`; `rejectsOneByteBeyondLabelAndHostLimits` | 63/253 accepted; 64/254 rejected |
| S003 ambiguous and unsafe host input | P001,P004 | `rejectsAmbiguousOrInvalidDnsNames` | empty labels, invalid edges, U-label and authority syntax all reject |
| S004 typed IPv4/IPv6 identity | P005,P006 | `acceptsTypedIpv4AndIpv6WithoutDns`; `rejectsWrongLengthsAndIpv4Zones` | exact family lengths and IPv6-only zone rule |
| S005 immutable address ownership | P007 | `addressOwnsAnImmutableOctetSnapshot` | input and returned-array mutation cannot change the address |
| S006 zone and port boundaries | P006,P008 | `ipv6ZoneAndPortBoundariesRemainTypedIdentity`; `rejectsEmptyAndOversizedIpv6Zones` | zone participates in equality; empty/65-byte zones reject; ports 0/65535 retain exactly |

## Acceptance decision

| Criterion | Evidence | Result |
|---|---|---|
| DNS names are typed and normalized | S001 through S003 | PASS |
| IPv4 and IPv6 are distinct typed values | S004 | PASS |
| IPv6 zone is explicit and bounded | S004,S006 | PASS |
| port is separate and range-safe | `UInt16` endpoint field plus S006 | PASS |
| ambiguous or invalid authority is rejected | S003 rejects authority syntax at the host boundary; M5-002 owns URL authority parsing | PASS |
| no implicit DNS | constructors contain validation/copy logic only; architecture guard forbids `std.net` outside its adapter | PASS |

## Commands and results

Focused tests:

```text
env DISABLE_ZOXIDE=1 /home/elliot/.codex/scripts/codex_cangjie_env --cwd /home/elliot/playground/Wirestack cjpm test '--filter=HostNameTest.*,EndpointTest.*' --no-color --no-progress
```

Result: exit 0. All nine selected cases passed; 498 unrelated cases were
skipped.

Architecture guard:

```text
python3 tools/architecture_guard.py --root . --format text
```

Result: exit 0, `architecture guard: PASS`.

Canonical repository gate:

```text
env DISABLE_ZOXIDE=1 /home/elliot/.codex/scripts/codex_cangjie_env --cwd /home/elliot/playground/Wirestack ./scripts/check
```

Result: exit 0. Python validation suites passed, the architecture guard passed,
`cjpm check` and `cjpm build` succeeded, and all 507 Cangjie tests passed with
zero skipped, errors or failures. The build reported one pre-existing unused
function warning in `src/internal/http1/connection_pool.cj`.

## Compatibility

No production declaration or behavior changed. A production-source-scoped
declaration diff returned `compatible` with no changed declarations. The
generic diff parser over-classifies local values inside test bodies as public
declaration changes, so that test-only result is not used as an API verdict.

## Remaining boundary

M2-001 does not implement DNS resolution, route selection, IDNA U-label to
A-label conversion or HTTP URL parsing. At M2-001 completion, the Linux
production resolver still awaited the bounded non-carrier backend in M2-003.
M2-003 is now complete. UP-007 remains an optional future upstream enhancement
and was never a dependency of M2-001 or the Linux release.
