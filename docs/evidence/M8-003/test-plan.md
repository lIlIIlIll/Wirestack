# M8-003 test plan: Unix-domain and capability-scoped raw sockets

This plan covers Linux x86_64 glibc Unix-domain adapters and the explicit raw
socket capability boundary. Privileged packet/raw I/O is intentionally not
claimed without a native capability adapter; unsupported combinations are
fail-closed evidence, not silent success.

## Semantics

| ID | Contract or failure scenario | Expected result |
|---|---|---|
| P001 | Unix pathname, abstract byte-name and unnamed endpoint forms are distinct | Values preserve the selected form and own their bytes; unnamed cannot be bound as a named listener |
| P002 | Abstract Unix names are byte sequences, not UTF-8 strings | Abstract stream and datagram loopback work with the leading NUL byte preserved |
| P003 | Unix stream and datagram operations use the same bounded context/lifecycle contract | Partial/exact stream helpers and datagram message boundaries remain available |
| P004 | Raw domain/protocol capability is independent from destination addressing | Raw construction fails closed when no privileged adapter is installed |
| P005 | Unsupported AF_PACKET, AF_NETLINK, SOCK_SEQPACKET and ancillary APIs are explicit | Capability report and evidence identify these exclusions; no fake native handle is returned |

## Fault-injection matrix

| ID | Injection | Expected result |
|---|---|---|
| S001 | Abstract name contains arbitrary bytes | Endpoint and native Unix address preserve bytes without UTF-8 conversion |
| S002 | Attempt to bind unnamed Unix endpoint | Stable address/invalid-state error |
| S003 | Attempt raw open for IPv4, IPv6, packet and netlink | Stable `Unsupported` error; no object enters the default artifact |
| S004 | Raw I/O requested after close | Stable `Closed` error if a future adapter supplies a handle |
| S005 | Privileged capability unavailable | Task records BLOCKED capability rather than PASS |

## Test-plan matrix

| ID | Scenarios | Command or evidence | Result |
|---|---|---|---|
| T001 | P001,P002,P003 | `<home>/.codex/scripts/codex_cangjie_env cjpm test src/net --no-progress --no-color` | PASS (16/16 native Linux cases) |
| T002 | P004,P005,S003,S004,S005 | `unsupportedRawDomainsFailClosed` plus capability report | PASS for fail-closed behavior; privileged raw I/O BLOCKED/NOT_IMPLEMENTED |
| T003 | S001,S002 | `NetworkFoundationContractTest` endpoint checks and Unix listener adapter | PASS |
| T004 | P001..P005 | `python3 tools/architecture_guard.py --format json` | PASS; no std.net or native descriptor leakage |

No non-Linux emulator, one-hour SSE profile or 86,400-second soak is run by
this task.
