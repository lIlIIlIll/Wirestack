# M8-004 DNS wire client and resolver policy

Status: COMPLETE for the Linux DNS task acceptance scope, including PR #160 corrections. All twelve commands pass with Cangjie 1.1.3 and cjdoc 0.7.2. `evidence.json` is the canonical source-candidate and report index. Publication and merge status are separate from local qualification.

The implementation is isolated in a dedicated publication checkout, based on merged M8-003 commit `12d2b2a0bc8a906030ed771490b2cf0e562d49b4`. The original workspace is not modified.

## Qualified implementation

- Bounded DNS wire parser for A, AAAA, CNAME, SRV, TXT, MX, PTR, SOA and opaque unknown records.
- UDP identity validation before TCP truncation fallback; bounded query admission, caching and cancellation.
- Immutable resolver configuration, bounded trusted local hosts snapshot, search/ndots policy and an existing Happy Eyeballs connector integration.
- Linux transaction IDs read from `/dev/urandom`. Failure to read entropy fails the query; there is no predictable-ID fallback.

The parser accepts ASCII alphanumeric, hyphen and underscore name labels. Hyphens cannot occur at label edges. Binary TXT and unknown RDATA are preserved. Compression pointers must refer backward to a previously validated name boundary. These constraints are not a claim to support arbitrary escaped or binary DNS names.

`Resolver.resolve(String, ...)` retains explicit trailing-dot intent. The existing `HostName` value has already removed that dot. `Resolver.connect` returns a caller-owned transport and shares one absolute budget across DNS and TCP attempts. Closing a resolver does not close connections already returned to callers.

`queryTimeout` limits DNS resolution, not TCP connection attempts. `Resolver.connect` passes the caller's context to Happy Eyeballs. System nameserver entries with named or out-of-range IPv6 zones are ignored. Numeric UInt32 scope IDs are retained.

Hosts files are snapshotted during construction. Reloading requires a new resolver. Configuration file paths must refer to trusted local regular files; bounded reads do not make arbitrary filesystem operations cancellable.

## Executed development checks

- `cjpm check`: dependency/order check passed. This is not compilation proof.
- Initial `cjpm test src/net --parallel 1 --no-progress --no-color`: compiler rejected the uncompressed-name parser's missing terminal return. Replaced the unconditional loop with a cursor-bound loop and an explicit malformed-name terminal error.
- The same network command then passed 71/71 tests, with no skipped or failed cases.
- After adding `Resolver.connect`, the same command again passed 71/71.
- Focused `DnsResolverPolicyTest`: the hosts-precedence case first failed with one unwanted DNS query. After moving exact-name hosts lookup before DNS search, all nine policy cases passed; 71 other cases were filtered. Raw captures are in `development/hosts-precedence-red.log` and `development/hosts-precedence-green.log`.

The integrated network suite passed 82/82, with zero skips or failures. The raw result is `development/network-82-green.log`. The independent native consumer passed all eleven modes in `native-dns.json`, including all response identity fields, rejection of invalid TC responses before TCP fallback, LRU eviction, TTL limits, lookup-wide CNAME bounds, name-wide NXDOMAIN caching, the sixteenth search candidate, cancellation and real DNS-to-TCP exchange.

## Reproduced and corrected findings

Native runs confirmed and corrected three cache defects. `native-cache-red.json` records an unrelated authority SOA suppressing the required second query. `native-cname-red.json` and its consumer stderr record stale positive alias reuse after a delayed hop. `native-negative-cname-wire-red.json` records seven queries instead of the required eight: the expired negative alias was reused. Expiration is now the earliest absolute lifetime measured at each response, for both positive and negative entries; negative caching requires an enclosing SOA owner. Recursive responses do not require the AA bit. The same native scenarios pass in `native-green.json`.

Independent review found five further defects. The original findings are preserved without changing their verdicts in `development/wire-review-original.json` and `development/policy-review-original.json`.

- Legal authority NS compression into an additional owner was rejected. `development/legacy-glue-red.log` records the public parser failure. The fourteen-case parser run in `development/legacy-glue-green.log` passes after registering genuine legacy name-bearing RDATA boundaries.
- Cross-response CNAME traversal reset the eight-edge bound and lost intermediate loop history.
- Same-response NXDOMAIN omitted CNAME TTL from negative expiration.
- NXDOMAIN caching was incorrectly limited to the queried address family.
- Absolute-first search omitted the final eligible suffix.

The last four failures are captured in `native-review-red.json`. The same ten-mode matrix passes in `native-review-green.json`; the expanded eleven-mode matrix passes in `native-scenario-fixed.json`.

`native-scenario-green.json` is a failed compilation attempt despite its historical filename. The consumer incorrectly referenced `ResolveResult.completedAt`; the public field is `ResolveResult.diagnostics.completedAt`. It is not runtime regression evidence. The corrected consumer compiles and executes in `native-scenario-fixed.json`.

PR #160 identified an incorrectly shortened connection deadline and unsupported named IPv6 nameserver zones. `development/pr160-policy-red.stdout.log` records both failures before the fixes. `development/pr160-network-green.stdout.log` records 84 passing network tests afterward.

The same run executes deterministic parser mutation fuzzing with seed 8004 and twelve valid wire messages. It checks 8,544 generated input cases: 3,013 are accepted and 5,531 are rejected. Accepted messages must retain section counts and owned record bytes after input and returned-copy mutation. This is bounded mutation testing, not coverage-guided fuzzing.

The second PR review reproduced two further failures: one address family's error discarded the other family's usable addresses, and a queued call reported SystemFailure on close. Both regressions pass after the corrections in `pr160-second-review.json`. The queue test waits for all three excess callers to finish before closing, proving the remaining caller entered the one-slot queue.

The third review found that direct configuration still accepted unsupported nameserver zones. Construction now rejects named and overflowing zones with IllegalArgumentException before a client can attempt I/O. `pr160-third-review.json` records the failing constructor regression and the passing correction. System-file parsing continues to ignore unsupported entries.

The boundary review reproduced three failures and then passed 89 network tests. DNS transport errors now retain endpoints, with the selected nameserver as a fallback when receive errors lack a remote endpoint. Public summaries reject oversized section and combined-record counts before copying. Hosts snapshots ignore unsupported IPv6 zones. `pr160-boundary-review.json` records the raw red/green runs. Endpoint propagation uses an internal constructor; existing public signatures are unchanged.

The failover review found that a silent server consumed the whole query budget and prevented later attempts. Attempts now share the remaining absolute budget; cancellation and total expiry stay terminal. RCODE errors and active cancellation retain the selected nameserver. `pr160-failover-review.json` records the deadline and endpoint failures, followed by 92 passing network tests.

The declaration inventory contains nine added `wirestack.net` types, no removed or changed existing declarations, and unchanged aliases. This comparison does not prove binary or forward compatibility. Consumers must disambiguate the existing `wirestack.Resolver` interface and new `wirestack.net.Resolver` class when importing both packages.

## Final acceptance

`task-check.json` records all twelve successful commands and their raw captures in `development/pr160-acceptance/`. Earlier qualification captures remain in `commands/`. `pr160-review.json` distinguishes the daily-SDK development reproductions from the complete Cangjie 1.1.3 acceptance run.

| Gate | Observed result |
|---|---|
| Plan, architecture and task contract | PASS |
| `cjpm check` and `cjpm build` | Exit 0 |
| Network tests | 92 passed, zero skipped, zero failures |
| Transport and connector tests | 50 passed, 17 skipped, zero failures; Performance tags excluded |
| Independent native consumer | Eleven modes PASS |
| Static API baseline | 274 declarations, 103 aliases |
| cjdoc 0.7.2 | 1,236 symbols and 545 parameters documented |
| `scripts/check` | PASS; Cangjie suite 682 passed, 23 skipped, zero failures |
| Selected Python regressions | 116 passed |

The first acceptance attempt is retained in `development/acceptance-first/`. Its failures were a plan heading that did not match the validator, missing DNS files in the documentation inventory, and a TCP/UDP peer port collision. The runner now reserves a TCP port before binding UDP, limits reservation to sixteen attempts and closes partial ownership on failure. `development/port-reservation-smoke.json` records real collisions, exhaustion and descriptor cleanup. `raw-log-closure.json` verifies 236 raw log references across thirteen native reports.

Development failures precede the final source-candidate commit. Their raw logs and recorded source digests are historical observations, not a separately published baseline. `review-dispositions.json` links the five original findings to executed red/green evidence. `compatibility-inventory.json` keeps declaration inventory proof separate from untested binary and forward compatibility.

No non-Linux execution, DNSSEC, encrypted DNS, release signature, performance percentile or final 86400-second soak is claimed.
