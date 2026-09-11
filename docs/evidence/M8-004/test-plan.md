# M8-004 DNS wire and resolver qualification

Status: COMPLETE for Linux DNS task acceptance, including PR #160 review corrections. The network package passed 100 tests with no skips or failures. All twelve native modes and all twelve acceptance commands passed with Cangjie 1.1.3. `evidence.json` binds the final source candidate and reports.

Scope: Linux x86_64 glibc, pinned Cangjie toolchain, real loopback UDP/TCP peers. Original workspace drafts and historical reports are not current evidence. DNS names use the documented ASCII profile; TXT and unknown RDATA retain binary bytes. No DNSSEC, encrypted DNS, non-Linux execution or final release soak is claimed.

## Control-flow paths

| ID | Entry and branch | Observable result |
|---|---|---|
| P001 | Complete wire parse | Validated header, questions, ordered sections and owned records |
| P002 | Malformed or over-limit wire parse | Structured resolve error; bounded work and no partial accepted message |
| P003 | UDP query response validation | Only matching server, transaction, opcode, question, class and type can succeed |
| P004 | Validated TC response | Length-framed TCP fallback under the same absolute deadline |
| P005 | Address extraction and CNAME traversal | Answer-owner-only addresses; bounded aliases and minimum absolute expiry |
| P006 | Positive or negative cache | Capacity bound, immutable expiry and distinct NXDOMAIN/NODATA classification |
| P007 | Admission, cancellation and close | Bounded active/queued callers, wakeup, socket cleanup and stopped admission |
| P008 | Configuration and hosts snapshot | Bounded trusted regular-file input, immutable settings and family-filtered hosts |
| P009 | Search and ndots | Deduplicated candidate order; explicit absolute-name bypass |
| P010 | Resolver-to-connector integration | DNS and all Happy Eyeballs candidates consume one deadline |

## Semantics

| ID | Paths | Input or state | Required assertion |
|---|---|---|---|
| S001 | P001 | A/AAAA/CNAME/SRV/TXT/MX/PTR/SOA/unknown | Exact decoded data, targets, TTL and section order |
| S002 | P002 | Compression loop, forward/out-of-range target, excessive hops | Reject without accepting a name or consuming adjacent RDATA |
| S003 | P002 | Invalid labels, record lengths, TXT segments, count/size bounds, trailing bytes | Structured rejection; no invented record |
| S004 | P001 | Caller mutates source arrays or returned copies | Previously parsed record identity/data remain unchanged |
| S005 | P003 | Wrong source, ID, QR/opcode, question/class/type | No poisoned result or cache insertion |
| S006 | P004 | TC with incomplete RR body but valid envelope | Real TCP request and complete validated response |
| S007 | P004 | Wrong TC identity, repeated TCP TC, partial length or payload | No unauthorized fallback; bounded error/cleanup |
| S008 | P005 | Unrelated answer, authority/additional addresses, conflicting alias/address | Reject or ignore unrelated data, never return poisoned address |
| S009 | P005,P006 | Alias loop, hop bound, delayed multi-hop TTL | No loop; earlier alias expiry cannot be extended by later I/O |
| S010 | P006 | Positive cache hit, TTL zero, expired entry, full cache | No hit refresh, no TTL-zero retention, bounded entries |
| S011 | P006 | NXDOMAIN and NODATA with relevant authority SOA | Distinct errors; min SOA TTL/minimum and alias lifetime cap |
| S012 | P006 | Missing/unrelated SOA or transient error | No invented negative cache lifetime |
| S013 | P007 | Pre-cancelled, expired, queued, admission full, repeated close | Stable errors, no new I/O, bounded waiting, joined owned cleanup |
| S014 | P007 | Cancel/close during UDP receive or partial TCP frame | Real blocked operation terminates; no leaked owned socket |
| S015 | P008 | Tabs/comments, repeated search/domain, invalid IPv4/IPv6, named or out-of-range zones, ndots limits | Correct bounded configuration; only numeric UInt32 scope IDs retained |
| S016 | P008 | Missing/nonregular/oversized hosts file; aliases and family filtering | Safe fallback or correct HostsFile result; no partial oversized-file interpretation |
| S017 | P008 | Config array mutation and file replacement after construction | Existing resolver retains its documented snapshot |
| S018 | P009 | Absolute-first/search-first, duplicate/overlong suffixes, trailing dot | Exact query order and at most sixteen candidates |
| S019 | P010 | Real DNS answer followed by TCP service exchange | Correct bytes through returned public transport |
| S020 | P009,P010 | DNS/retry/search consumes caller deadline; connection outlives queryTimeout within caller deadline | No timeout reset or DNS-only cap on TCP attempts; no late success |
| S021 | P001,P002 | Deterministic byte replacements, multi-byte mutations, truncations and trailing bytes across twelve seeds | Structured rejection or complete sections with owned record bytes |
| S022 | P005 | One address family fails with TemporaryFailure or SystemFailure | Return the other family's usable addresses; retain terminal cancellation and timeout |
| S023 | P007 | One active caller, one queued caller, three completed admission rejections before close | Active and queued calls return Cancelled; new calls remain closed errors |
| S024 | P008 | Direct construction with named or overflowing nameserver zones | IllegalArgumentException before a client can retry an unsupported endpoint |
| S025 | P003,P004 | UDP receive timeout and owned TCP fallback closure | Top-level ResolveException retains selected nameserver and available local socket |
| S026 | P001,P002 | Public summary section overflow and combined-record boundary | Reject counts above 65,535 before copying; retain the final record at the accepted boundary |
| S027 | P008 | Hosts entries with named, overflowing, numeric and absent IPv6 zones | Ignore unusable zones and preserve supported HostsFile results |
| S028 | P003,P004 | Silent primary, healthy secondary, and successful later pass under a shorter caller deadline | Remaining budget reaches later attempts without extending the total deadline |
| S029 | P003 | SERVFAIL followed by REFUSED from another server | Exhausted error retains the last responding nameserver |
| S030 | P003,P007 | Active query cancellation with pending retries | Cancelled error retains its nameserver; the secondary receives no query |
| S031 | P008,P009 | Real glibc search suffix with absolute, manually expanded and direct DNS names | Only exact intended names reach the isolated DNS peer |
| S032 | P003,P008 | Direct and system-file numeric scopes with leading zeros or zero scope | Canonical nameserver identity matches native endpoint representation |
| S033 | P003,P004 | Matching malformed UDP response and repeated TC over TCP | Structured failure retains the selected peer and cause |
| S034 | P008,P009,P010 | Numeric hosts override, configured nameserver, family mismatch, cancellation and native literal connect | IPv4 literal remains unchanged, returns Static, obeys context/family policy and sends no DNS query |
| S035 | P008,P009 | A 253-byte canonical DNS name through the exact system fallback | Native input accepts the appended root dot and resolves the full name |
| S036 | P003,P005,P006 | Live NXDOMAIN, CNAME NXDOMAIN and NODATA followed by cached lookups | Live errors retain the responding peer; cached errors cause no query and claim no new remote response |
| S037 | P005,P006 | Any-family lookup fills maxResults=1 from A while AAAA is silent | Return the sufficient A result; neither uncached nor cached lookup sends the unnecessary AAAA query |
| S038 | P003,P005,P006 | A returns SERVFAIL and AAAA returns authoritative NXDOMAIN | Live and immediately cached Any lookups agree on NameNotFound; live error retains its responding peer |
| S039 | P003,P005 | FORMERR or conflicting CNAME targets after a validated wire response | Post-query interpretation errors retain the responding nameserver |
| S040 | P008 | Eight equivalent numeric scope spellings followed by a distinct server | Canonical deduplication retains both distinct endpoints within the eight-server bound |
| S041 | P005,P006 | Conflicting A/AAAA canonical names with either family prewarmed, then both cached | Mixed live/cache conflict retains the live peer; cached-only conflict has no new remote response |
| S042 | P003,P005,P006 | NXDOMAIN without SOA, followed by an available AAAA answer | Any lookup stops after one query with NameNotFound; a later independent IPv6 lookup can still query and succeed |
| S043 | P007,P008 | One-second client adopted under a thirty-second resolver, then equivalent settings | Reject mismatch without taking or closing the client; matching adoption transfers close ownership |
| S044 | P008 | Duplicate %1/%01 hosts addresses and a zero-scoped distinct address with maxResults=2 | Return distinct canonical addresses without duplicates consuming the result bound |
| S045 | P003,P005,P006 | Cached A followed by NXDOMAIN without SOA or with zero-TTL SOA | Purge stale A; later Any/maxResults=1 query receives a fresh changed address without an invented negative lifetime |

## Test-plan matrix

| ID | Paths | Scenarios | Execution/evidence | Status |
|---|---|---|---|---|
| T001 | P001,P002 | S001,S002,S003,S004 | Public DnsMessageParser regressions; development/legacy-glue-green.log and development/network-82-green.log | PASS |
| T002 | P003,P004 | S005,S006,S007 | Loopback DnsClient tests; native-scenario-fixed.json fallback-identity with seven rejected candidates and no premature TCP fallback | PASS |
| T003 | P005,P006 | S008,S009,S010,S011,S012 | Network regressions; native-scenario-fixed.json basic, cache-policy, cache-capacity, cname-ttl, cname-bounds, combined-negative and negative-scope | PASS |
| T004 | P007 | S013,S014 | Network admission tests; native-scenario-fixed.json lifecycle | PASS |
| T005 | P008,P009 | S015,S016,S017,S018 | Public Resolver/config tests; development/hosts-precedence-green.log and native-scenario-fixed.json search-boundary | PASS |
| T006 | P009,P010 | S019,S020 | Public Resolver.connect shared-deadline tests; native-scenario-fixed.json connect | PASS |
| T007 | P001,P002,P003,P004,P005,P006,P007,P008,P009,P010 | S001,S002,S003,S004,S005,S006,S007,S008,S009,S010,S011,S012,S013,S014,S015,S016,S017,S018,S019,S020 | task-check.json, public-api-inventory.json, docs-report.json and evidence.json | PASS |
| T008 | P001,P002 | S021 | DnsWireFuzzTest; development/pr160-network-green.stdout.log, seed 8004, 8,544 inputs | PASS |
| T009 | P008,P009,P010 | S015,S020 | development/pr160-policy-red.stdout.log and development/pr160-network-green.stdout.log | PASS |
| T010 | P005,P007 | S022,S023 | pr160-second-review.json; development/pr160-second-red.stdout.log and development/pr160-second-green.stdout.log | PASS |
| T011 | P008 | S024 | pr160-third-review.json; directConfigRejectsUnsupportedNameserverZonesBeforeQueries red/green regression | PASS |
| T012 | P001,P002,P003,P004,P008 | S025,S026,S027 | pr160-boundary-review.json; three failing regressions before correction, 89 network tests passing afterward | PASS |
| T013 | P003,P004,P007 | S028,S029,S030 | pr160-failover-review.json; native failover, RCODE and cancellation red/green regressions | PASS |
| T014 | P003,P004,P008,P009 | S031,S032,S033 | pr160-fallback-review.json; 93 network tests and real glibc namespace red/green proof | PASS |
| T015 | P008,P009,P010 | S034,S035 | pr160-literal-review.json; 94 network tests and independent native maximum-name/literal-connect red/green proof | PASS |
| T016 | P003,P005,P006 | S036,S037 | pr160-response-review.json; executed negative-peer and full-capacity regressions, 95 network tests passing | PASS |
| T017 | P003,P005,P006 | S038,S039 | pr160-interpretation-review.json; three failing regressions before correction and 97 network tests passing afterward | PASS |
| T018 | P005,P006,P008 | S040,S041 | pr160-aggregation-review.json; two failing regressions before correction and 99 network tests passing afterward | PASS |
| T019 | P003,P005,P006 | S042 | pr160-nxdomain-review.json; one failing runtime regression before correction and 100 network tests passing afterward | PASS |
| T020 | P003,P005,P006,P007,P008 | S043,S044,S045 | pr160-ownership-review.json; three failing regressions before correction and 102 network tests passing afterward | PASS |

A local regular file can still block in the operating system or filesystem. File input is a trusted-local configuration precondition, not a claim of cancellable arbitrary filesystem I/O. Hosts are captured during construction, outside lookup contexts. The String resolve overload preserves the trailing root dot; HostName already canonicalizes it away.

Final evidence must retain exact argv, exits, toolchain, raw output and source digests. Native run results, injected fixtures and source inspection remain separate. A source finding alone is not red/green proof. No current coverage percentage, performance percentile, release signature or 86,400-second soak is claimed here.
