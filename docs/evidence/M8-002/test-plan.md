# M8-002 test plan: Linux synchronous TCP and UDP

This plan covers the Linux x86_64 glibc implementation of bounded synchronous
stream and datagram sockets. It does not claim Unix-domain capability,
privileged raw I/O, DNS policy, HTTP parity, TLS context replacement or the
final release soak; those are owned by M8-003 through M8-007.

## Semantics

| ID | Contract or failure scenario | Expected result |
|---|---|---|
| P001 | TCP descriptors are non-blocking and close-on-exec | Capability report is true and native loopback operations complete through bounded readiness waits |
| P002 | Stream operations can make partial progress and exact/all helpers finish | A large payload is echoed with partial `read`, `readExact` and `writeAll` |
| P003 | One read and one write may overlap, but same-direction operations are exclusive | Concurrent same-direction read returns stable `ConcurrentOperation`; one reader and one writer remain usable |
| P004 | Cancellation and close wake an affected operation without implicit cancellation of the socket | Blocked read reports `Cancelled` or `Closed`; a still-open socket can continue after cancellation |
| P005 | Datagram sends remain atomic and receives report truncation | Oversized receive capacity returns one bounded payload with `truncated=true`; exact-size receive is false |
| P006 | Datagram payload and socket resource bounds are enforced | Payloads above the bounded maximum return `MessageTooLarge` |

## Fault-injection matrix

| ID | Injection | Expected result |
|---|---|---|
| S001 | Pre-cancelled connect | Stable `Cancelled` before a descriptor is exposed |
| S002 | Second same-direction read | Stable `ConcurrentOperation`, with the first read still authoritative |
| S003 | Close while read is waiting; repeated close | Waiting operation wakes as `Closed`; repeated close is harmless |
| S004 | Datagram larger than destination | Message boundary is preserved and truncation is explicit |
| S005 | Datagram larger than protocol maximum | Stable `MessageTooLarge`; no partial send is reported |
| S006 | Restricted socket sandbox | Classified as environment `Operation not permitted`, never promoted to a product PASS |

## Test-plan matrix

| ID | Scenarios | Command or evidence | Result |
|---|---|---|---|
| T001 | P001,P002,P003,P004 | `<home>/.codex/scripts/codex_cangjie_env cjpm test src/net --no-progress --no-color` | PASS (native Linux runner, 16/16) |
| T002 | P005,P006 | Same native network suite | PASS (native Linux runner, 16/16) |
| T003 | S001,S002,S003,S004,S005,S006 | `python3 tools/repository/repository_tooling.py --root . validate-plan ...` and bounded task gate reports | PASS; sandbox-only socket denial remains diagnostic |
| T004 | P001..P006 | `python3 tools/architecture_guard.py --format json` | PASS; no public native descriptor or std.net leakage |

The task intentionally does not run any one-hour SSE profile or 86,400-second
soak. M8-007 owns the final release candidate and long-duration evidence.
