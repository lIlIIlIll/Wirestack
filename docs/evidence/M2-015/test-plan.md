# M2-015 native Linux network-emulation test plan

- Task: `M2-015`
- Platform: native Linux x86_64 glibc
- Scope: integration evidence only; no production API or connector behavior change
- Requirements: PRD CONN-002 through CONN-005, lifecycle invariant 9,
  M2 exit criteria, and benchmark network profiles

## API semantics

The gate calls the production `HappyEyeballsConnector` with a `StaticResolver`,
the production `StdNetTransportFactory`, one immutable parent
`OperationContext`, and real TCP sockets. The caller observes the winning
endpoint, ordered attempt diagnostics, terminal error category, elapsed time,
and closed winner ownership. The outer Linux gate owns only an ephemeral user
and network namespace, local test listeners, `tc` impairment, and process-tree
resource sampling.

The gate must not modify the host network, invoke a private runtime ABI, replace
the shared Deadline, or infer cleanup from exception text. Namespace teardown
is a final safety net, not evidence that the connector joined its candidates.

## Control-flow path matrix

| Path ID | Conditions and values | Runtime/compiler checks | Reachability | Notes |
|---|---|---|---|---|
| P001 | IPv6 is first and its real TCP handshake completes before `attemptDelay` | native IPv6 socket/connect | reachable | IPv6 wins; delayed IPv4 is skipped |
| P002 | IPv6 SYN is dropped; `attemptDelay` releases reachable IPv4 | native connect cancellation and close wakeup | reachable | IPv4 wins; IPv6 loser is cancelled and joined |
| P003 | reachable IPv6 runs under configured 20 ms RTT | `tc netem` packet statistics | reachable | real connect succeeds within the parent budget |
| P004 | reachable IPv6 runs under configured 100 ms RTT | `tc netem` packet statistics | reachable | real connect succeeds without premature fallback |
| P005 | repeated reachable IPv4 connects run under configured 1% loss | TCP retransmission and `tc` drop statistics | reachable | every iteration has one terminal result |
| P006 | two SYN-dropping candidates consume one 350 ms parent Deadline | Deadline and cancellation wake blocked native connects | reachable | failure is `TimedOut`; all attempts are joined |
| P007 | eight SYN-dropping candidates consume the same 350 ms parent Deadline | bounded candidate scheduling and native close wakeup | reachable | elapsed time does not become eight budgets |
| P008 | successful winner is closed and each native gate process terminates | `/proc` process-tree sampling | reachable | socket/thread/RSS trends are non-monotonic within limits |
| P009 | namespace or impairment prerequisite is absent or misconfigured | command exit and qdisc/filter counters | reachable error | gate fails closed; it never reports a skipped PASS |

## Input-domain and boundary partitioning

| Domain | Minimal value | Boundary/extended value | Invalid or fail-closed value |
|---|---|---|---|
| Address family | one reachable IPv6 | IPv6 first plus IPv4 fallback | unavailable IPv6 route or zero packets through configured rule |
| Candidate count | one reachable candidate | 2 and 8 blackholed candidates | empty plan, already rejected by production contract |
| Attempt delay | 250 ms for preferred-family profiles | 50 ms fallback; 20 ms multi-candidate staggering | negative, already rejected by production contract |
| Parent budget | 2 s reachable profile | shared 350 ms blackhole budget | expired context, covered by M2-014 deterministic tests |
| RTT | no impairment | 20 ms and 100 ms | qdisc configured but no packets observed |
| Loss | 0% | deterministic-seed 1% over repeated connects | qdisc reports no drops |
| Lifecycle | one connect and close | repeated blackhole fallback and loss connects | unfinished diagnostic, surviving process, or growing socket trend |

## State and side effects

- Pre-state: the disposable namespace owns only loopback addresses, qdiscs,
  filters, and local listeners created by this gate.
- Success: the caller owns exactly one winner and closes it; every other
  candidate has a terminal diagnostic before `connect` returns.
- Failure: the parent Deadline cancels all native attempts, returns one typed
  `TimedOut` result, and joins every candidate.
- Cleanup: listener threads stop, child processes exit, and the namespace is
  destroyed. Socket, thread, RSS, and process-count samples must not show a
  positive steady-state leak trend.

## Scenario matrix

| Scenario ID | Input | Pre-state | Triggered path IDs | Expected behavior | Required assertions | Type | Priority |
|---|---|---|---|---|---|---|---|
| S001 | IPv6 then IPv4; no impairment | dual-stack local listeners | P001,P008 | preferred IPv6 wins | Assert winner family IPv6, one successful attempt plus one skipped diagnostic, winner closed, clean exit | normal,platform | P0 |
| S002 | IPv6 SYN blackhole then IPv4; 64 repetitions | IPv4 listener and IPv6 drop filter | P002,P008 | IPv4 fallback wins every time | Assert two diagnostics per iteration, IPv6 loser `Cancelled`, zero connector-returned background attempts, bounded resource trend | regression,platform | P0 |
| S003 | IPv6 with 20 ms RTT | IPv6 listener and 10 ms per-direction netem delay | P003,P008 | native handshake succeeds | Assert IPv6 winner, qdisc packets observed, elapsed below parent Deadline, clean exit | platform,boundary | P0 |
| S004 | IPv6 with 100 ms RTT | IPv6 listener and 50 ms per-direction netem delay | P004,P008 | native handshake succeeds | Assert IPv6 winner, qdisc packets observed, elapsed below parent Deadline, clean exit | platform,boundary | P0 |
| S005 | IPv4 with deterministic 1% loss; 128 repetitions | IPv4 listener and seeded netem loss | P005,P008 | TCP retransmission still yields bounded success | Assert 128 winners and closes, qdisc drop count positive, no monotonic socket/thread/RSS growth | platform,regression | P0 |
| S006 | 2 blackholed IPv4 candidates; 350 ms Deadline | SYN drop filter for candidate subnet | P006,P008 | shared budget expires once | Assert typed `TimedOut`, two terminal diagnostics, elapsed within gate tolerance, clean exit | error,boundary | P0 |
| S007 | 8 blackholed IPv4 candidates; same Deadline | same filter and no listener | P007,P008 | candidate count does not multiply budget | Assert typed `TimedOut`, eight terminal diagnostics, elapsed differs from S006 only within tolerance | error,boundary | P0 |
| S008 | missing user namespace, `tc`, filter hits, or native test result | incomplete gate prerequisites | P009 | no acceptance artifact is emitted | Assert nonzero gate exit and `INCOMPLETE`/`FAIL`, never PASS | error,platform | P0 |

## Test-plan matrix

| Test ID | Scenario IDs | Path IDs | Input | Expected result | Assertions | Type |
|---|---|---|---|---|---|---|
| T001 | S001 | P001,P008 | native dual-stack available | IPv6 preferred winner | Assert family, diagnostics, close, process exit | minimal |
| T002 | S002 | P002,P008 | IPv6 SYN drop plus IPv4 listener, 64 runs | stable IPv4 fallback | Assert loser cancellation/join evidence and bounded resource trend | strengthened |
| T003 | S003 | P003,P008 | 20 ms RTT profile | successful native IPv6 connect | Assert qdisc traffic and elapsed budget | boundary |
| T004 | S004 | P004,P008 | 100 ms RTT profile | successful native IPv6 connect | Assert qdisc traffic and elapsed budget | boundary |
| T005 | S005 | P005,P008 | deterministic 1% loss, 128 runs | all connects complete | Assert positive drops, winner count, closes, bounded resource trend | strengthened |
| T006 | S006 | P006,P008 | two candidates, 350 ms | one shared timeout | Assert error code, diagnostic count, elapsed limit | minimal |
| T007 | S007 | P007,P008 | eight candidates, 350 ms | one shared timeout | Assert error code, diagnostic count, elapsed and S006 delta limits | boundary |
| T008 | S008 | P009 | forced prerequisite/counter/result failure | fail-closed gate | Assert nonzero result and no PASS report | strengthened |

## Coverage and reverse-review gaps

This task produces native integration evidence, not a line-coverage claim.
M2-014 already owns deterministic success/cancel and exact Deadline publication
races. M2-016 owns DNS-to-connected benchmark metrics. Global Windows, Apple,
Android, iOS, and Harmony evidence remains outside this Linux profile. The final
report must retain raw JSON and command output paths and must call any missing
qdisc counter, resource trend, or native execution a gate failure.
