# M8-004 test plan: DNS wire client and Linux resolver policy

This plan covers bounded DNS parsing, explicit UDP/TCP transport, response
validation, hosts-file lookup and search/`ndots` policy on Linux x86_64 glibc.
Happy Eyeballs remains the connector's policy consumer; this task only supplies
the ordered, bounded address result under one operation context.

## Semantics

| ID | Contract or failure scenario | Expected result |
|---|---|---|
| P001 | Parse bounded A/AAAA/CNAME/SRV/TXT/MX/PTR sections | Known lengths and embedded names validate; opaque data remains owned |
| P002 | DNS identity, question and server are validated | Mismatched transaction, question or source is rejected before caching |
| P003 | UDP truncation falls back to length-framed TCP | The same absolute context covers both transports and a complete A answer is returned |
| P004 | Resolver policy combines hosts file, search domains and `ndots` | Candidates are ordered and capped at 16; hosts entries retain `HostsFile` source |
| P005 | Negative results are bounded and cached | NXDOMAIN/NoData map to stable resolve codes and do not create unbounded state |
| P006 | Cancellation/deadline is shared by DNS operations | Pre-cancelled or expired contexts terminate without creating an independent timeout owner |

## Fault-injection matrix

| ID | Injection | Expected result |
|---|---|---|
| S001 | Compression pointer loop or out-of-range pointer | `SystemFailure`/malformed response; no cache insertion |
| S002 | Known RDATA length mismatch | Parser rejects A/AAAA/CNAME/SRV/MX/TXT malformed data |
| S003 | Transaction/question/source mismatch | Response is rejected and another bounded nameserver/attempt may be tried |
| S004 | UDP response advertises truncation | TCP fallback runs under the same `OperationContext` |
| S005 | NXDOMAIN or empty address answer | Stable `NameNotFound`/`NoData` and bounded negative cache |
| S006 | Hosts file exceeds size/line bound or contains invalid names | File is ignored safely; DNS policy remains authoritative |
| S007 | Search list creates duplicate/overlong candidates | Candidate generation remains bounded and de-duplicated |

## Test-plan matrix

| ID | Scenarios | Command or evidence | Result |
|---|---|---|---|
| T001 | P001,S001,S002 | `DnsMessageParser` malformed corpus in `cjpm test src/net` | PASS |
| T002 | P003,S003,S004 | Native UDP truncated response plus TCP fallback server | PASS (1.2 ms, native Linux) |
| T003 | P004,S006,S007 | Bounded temporary hosts file with IPv4/IPv6 and search policy | PASS |
| T004 | P005,S005 | Response-code and empty-answer handling | PASS |
| T005 | P006 | Shared `OperationContext` checks and existing cancellation tests | PASS |
| T006 | P001..P006 | `python3 tools/architecture_guard.py --format json` | PASS |

No non-Linux resolver run, one-hour SSE profile or 86,400-second soak is run
by this task.
