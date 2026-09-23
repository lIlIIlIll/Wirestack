# M9-003 UDP lifecycle test plan

Scope: Linux x86_64 glibc StdNet UDP lifecycle, IPv4 broadcast, and qualified IPv4/IPv6 multicast membership. M9-002 is a sealed prerequisite. This plan does not authorize commits, pushes, merges, or release publication. It does not add arbitrary native option pass-through, unbounded membership state, or non-Linux support claims.

## Control-flow paths

| Path ID | Condition | Expected terminal |
|---|---|---|
| P001 | Connected UDP disconnect succeeds, repeats, or is cancelled before admission | Peer selection is cleared only on native success; bind remains; repeated disconnect is idempotent; cancelled call leaves peer unchanged |
| P002 | Connected send after disconnect versus explicit sendTo | Connected send returns NotConnected; sendTo reaches its target from the same bound socket |
| P003 | Broadcast disabled, enabled, then disabled after traffic | Kernel option readback matches each setting; directed IPv4 broadcast fails while disabled and reaches the receiver while enabled |
| P004 | IPv4 and link-local IPv6 multicast membership on usable interfaces | Receiver joins exact group/interface, observes a real datagram, and leaves successfully |
| P005 | Duplicate, unmatched, invalid, native-failing, full, and closed-socket membership operations | Stable structured errors; max-16 bound; failed native join does not publish membership or poison the socket; close releases state |
| P006 | Disconnect overlaps active receive; cancellation, close, and abort race | Concurrent control is rejected; first terminal owner and exact-once completion are preserved |
| P007 | Installed package and source/API/capability/documentation evidence | Fresh extracted consumer uses only public APIs; native syscall observations and generated contract remain consistent |

## Semantics and scenario matrix

| Scenario ID | Input and pre-state | Path IDs | Expected behavior | Required assertions | Type |
|---|---|---|---|---|---|
| S001 | Bound IPv4 UDP socket connected to a local peer; successful and pre-cancelled disconnect | P001,P002 | Native disconnect clears peer without releasing local bind; pre-cancellation has no side effect | Peer property, local endpoint, repeated call, NotConnected send, explicit sendTo delivery, cancellation result | behavior,boundary |
| S002 | IPv4 broadcast option toggled around real loopback directed-broadcast sends | P003 | Disabled send fails; enabled send arrives; subsequent disable takes effect | Effective SO_BROADCAST readback and receiver payload | native |
| S003 | IPv4 multicast group/interface and IPv6 link-local group/interface | P004 | Exact native membership receives one sent datagram and leaves | Real payload delivery in IPv4 and IPv6 native scenarios | native |
| S004 | Duplicate/unmatched/unsupported-family/bad-interface operations; 16 active entries; close and reopen | P005 | No phantom state, no over-capacity entry, deterministic error, clean next socket | Typed error domain/code, native failure socket remains usable, recovery after leave/close | boundary,native,fault |
| S005 | Disconnect during blocked receive; pre-cancelled disconnect; repeated close around cancelled receive | P001,P006 | Control does not mutate peer during active receive; cancellation wins once; close remains idempotent | Barrier-controlled concurrency, terminal state, single completion | concurrency |
| S006 | Fresh archive installation and active send/receive probes | P007 | Public consumer builds outside checkout and real delayed syscalls are observed | Archive and input digests, markers, syscall trace, no checkout dependency | installed,native |
| S007 | API inventory, capability map, docs, and canonical repository gates | P007 | Declared support, backend preconditions, examples, and evidence agree | Generated documentation, capability correspondence, compatibility classification, full check | integration,compatibility |

## Test-plan matrix

| Test ID | Scenario IDs | Path IDs | Input | Expected result | Assertions | Type |
|---|---|---|---|---|---|---|
| T001 | S001,S002,S004 | P001,P002,P003,P005 | Public M9003UdpSocketTest | PASS | Disconnect semantics, retained binding, broadcast behavior, membership errors/bounds/recovery | regression,native |
| T002 | S005 | P001,P006 | Adapter M9003UdpLifecycleTest | PASS | Active-operation exclusion, cancellation ownership, blocked receive and idempotent close | concurrency |
| T003 | S001,S002,S003,S004,S005,S006 | P001,P002,P003,P004,P005,P006 | tools/m9_003_native_udp.py --offline | PASS | Fresh package extraction, all mapped prior and M9-003 scenarios, actual IPv4/IPv6 delivery, delayed syscall evidence | installed,native |
| T004 | S007 | P007 | Capability/API/documentation checks and scripts/check | PASS | API inventory/compatibility, architecture boundary, required native correspondence, generated docs and canonical gate | integration,compatibility |

## Evidence boundaries

Cross-compilation or a unit test is not native acceptance. IPv4 broadcast and both declared multicast families require real packet delivery; do not replace unavailable native observations with Unsupported. Keep interface identifiers numeric and transient; evidence must not record interface names or machine-specific paths. A task with only working-tree evidence is unsealed and cannot be marked COMPLETE. No compatibility claim extends beyond the documented additive source API and qualified Linux semantic capability change.

## Executed mapping

Exact commands, exit codes, scenario outcomes, normalized logs, input digests, and platform identity belong in verification.json and native-udp.json. A skipped, timed-out, compilation-only, or unavailable scenario is not a pass.
