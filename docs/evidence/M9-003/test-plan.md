# M9-003 UDP test plan

This plan maps the UDP disconnect, broadcast, and multicast contract to focused Cangjie tests and installed Linux consumers. Native acceptance applies only to `linux-x86_64-glibc`.

## Semantics

| Path | Action | Required observable result |
|---|---|---|
| P001 | Connect a bound UDP socket, send to its peer, disconnect twice, then use `send` and `sendTo`. | Disconnect clears the remote endpoint and retains the local binding. Connected `send` returns `NotConnected`; explicit `sendTo` still delivers from the retained binding. |
| P002 | Cancel disconnect before it runs, then exercise disconnect against an active receive and close a blocked receive. | A cancelled disconnect leaves the selected peer and open state unchanged. Active-operation exclusion returns `ConcurrentOperation`; cancellation or close completes the owning receive once with its defined terminal result. |
| P003 | Send IPv4 broadcast through an installed consumer and inspect the capability contract. | Native broadcast succeeds only when the target option is qualified. IPv6 and unqualified targets do not claim broadcast support. |
| P004 | Join, use, and leave IPv4 multicast membership on the qualified Linux target. | The installed consumer proves the declared IPv4 membership path and cleanup. |
| P005 | Join, use, and leave IPv6 multicast membership on the qualified Linux target. | The installed consumer proves the declared IPv6 membership path and cleanup. |
| P006 | Submit invalid, cross-family, duplicate, mismatched-interface, exhausted, and native-failure membership requests. | Inputs and state return the documented error category. A native failure leaves the socket open; leaving a group frees its bounded slot; close remains idempotent. |
| P007 | Compare the previous and current public `UdpSocket` declarations. | Additive disconnect and membership methods preserve existing declarations; removed, changed, or duplicate declarations fail the compatibility check. |
| P008 | Generate capability, API-inventory, and documentation reports from the native observations. | Every claimed UDP capability has matching native evidence, and generated API and HTML output agree with the documented contract. |

## Test-plan matrix

| Scenario | Path | Test IDs | Required observation |
|---|---|---|---|
| S001 | P001 | T002, T004 | Repeated disconnect clears the peer, retains the local endpoint, rejects connected send, and preserves explicit `sendTo`. |
| S002 | P002 | T002 | Cancelled disconnect reports `Cancelled` without changing the selected peer or socket state. |
| S003 | P002 | T002, T004 | Disconnect during receive is rejected; cancellation preserves single terminal ownership. |
| S004 | P002 | T002 | Close during blocked receive completes with `Closed`; repeated close does not complete the operation twice. |
| S005 | P002 | T004 | The installed active-send consumer records native send behavior and control-operation exclusion. |
| S006 | P003 | T004, T005 | The installed IPv4 broadcast consumer passes and the report does not claim IPv6 broadcast. |
| S007 | P004 | T002, T004, T005 | IPv4 membership succeeds natively and can be removed. |
| S008 | P005 | T004, T005 | IPv6 membership succeeds natively and can be removed. |
| S009 | P006 | T002, T004, T005 | Invalid address/index, family mismatch, duplicate membership, wrong interface, table exhaustion, native failure, and close cleanup match the contract. |
| S010 | P007 | T006 | The API compatibility report accepts additive methods and rejects removed, changed, or duplicate declarations. |
| S011 | P008 | T005, T007 | Capability rows, public API inventory, generated Markdown, and HTML report the qualified contract. |
| S012 | P001, P002, P003, P004, P005, P006 | T008, T009 | Existing repository checks and the long gate pass without widening platform claims. |

## Test commands

| Test ID | Command | Purpose |
|---|---|---|
| T001 | `python3 tools/repository/repository_tooling.py --root . validate-plan docs/evidence/M9-003/test-plan.md --json` | Validate that each semantic path and scenario has a plan entry. |
| T002 | `cjpm test src/net src/internal/transport_stdnet --filter=M9003*.* --no-progress --no-color` | Run focused public and std.net adapter lifecycle cases. |
| T003 | `python3 -m unittest tools.tests.test_network_capabilities tools.tests.test_m9_001_native_capabilities tools.tests.test_m9_003_api_compatibility -v` | Check capability evidence and API compatibility rules. |
| T004 | `python3 tools/m9_003_native_udp.py --offline` | Execute installed native consumers for disconnect, broadcast, both multicast families, membership errors, active receive, and active send. |
| T005 | `python3 tools/check_network_capabilities.py --check --require-native --native-report docs/evidence/M9-003/native-udp.json --report docs/evidence/M9-003/capabilities.json --api-report docs/evidence/M9-003/api-inventory.json` | Require native observations for every declared capability. |
| T006 | `python3 tools/m9_003_api_compatibility.py` | Check the public UDP API compatibility contract. |
| T007 | `scripts/check-docs --html --json --output docs/evidence/M9-003/docs-report.json` | Generate and validate API documentation and HTML. |
| T008 | `scripts/check` | Run the canonical repository checks. |
| T009 | `scripts/check-long M9-003 --json --output docs/evidence/M9-003/long-check.json` | Run the task's long-running acceptance gate. |
