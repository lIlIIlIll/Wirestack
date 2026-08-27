# M6-025 HTTP/2 facade concurrency and termination evidence

- Task: `M6-025`
- Status: **COMPLETE**
- Platform: native Linux x86_64 glibc
- Date: 2026-08-27, UTC+8
- Compiler: Cangjie 1.1.0-alpha.20260817040003, cjnative
- Package manager: cjpm 1.1.3

## Failure and root cause

The bounded three-case process first failed with
`HTTP/2 writer deadline exceeded`; the concurrent stream-limit case then did
not let the unittest process terminate before the 90-second outer bound. Each
case reproduced independently, so the failure was not cross-test state left by
an earlier case.

At the deadline, the timed-out ticket had already left the write queue:
`writerRunning=true`, `pendingWrites=0`, and `pendingBytes=0`. The writer was
therefore blocked in the active TLS transport write, not waiting for an HTTP/2
queue notification. A bounded source A/B then proved:

- M3-028 connection-field scratch reuse: the three facade cases failed or hung.
- Operation-local arrays: all three cases passed and the process exited, but the
  M3-028 gate failed bulk and body-memory thresholds because every call allocated.
- Separate persistent read/write arrays: the facade failure remained.
- Exclusive scratch leases: all three cases passed; the active array is removed
  from its cache slot until the operation returns, so no field retains an alias
  to mutable full-duplex scratch.

The final pump has one bounded cache per direction, creates an explicit pump for
each production client/server TLS connection, clears cached scratch at idle and
close, and uses 2 KiB incremental handshake scratch. It does not add a timeout
owner, alter the five-second request deadline, or change public APIs.

## Acceptance results

| Gate | Result |
| --- | --- |
| Three focused facade cases | PASS; 3 passed, 0 failed, 0 timeout; 0.55 s |
| Same-process 100-round profile | PASS; 300 scenario executions, 0 failed, 0 timeout; retained junit run 65.52 s |
| TLS engine non-Performance tests | PASS; 60/60 |
| `src/http` non-Performance package | PASS; 66 passed, 2 Performance-tagged skipped; 6.82 s |
| `scripts/check` | PASS; tool tests, architecture guard, `cjpm check`, build and 538/538 non-Performance Cangjie tests; 20 Performance-tagged skipped |
| M3-028 requalification | PASS; all threshold checks |

The 100-round junit report is
[`linux_glibc_x86_64/tests/test-wirestack.http.Http2FacadeTerminationProfileTest.xml`](linux_glibc_x86_64/tests/test-wirestack.http.Http2FacadeTerminationProfileTest.xml).
The complete JSON-formatted M3-028 machine-readable report is
[`linux_glibc_x86_64/m3-028-requalification.report`](linux_glibc_x86_64/m3-028-requalification.report).

## M3-028 requalification details

| Requirement | Result | Decision |
| --- | ---: | --- |
| Bulk throughput versus stdx | 1.4494 ratio; minimum 0.90 | PASS |
| Full handshake P50 versus stdx | 0.1112 ratio; maximum 1.10 | PASS |
| Full handshake P95 versus stdx | 0.1326 ratio; maximum 1.20 | PASS |
| TLS 1.3 resumed handshake | 11/11 measured rounds | PASS |
| Body-size memory | 4,788 KiB peak growth; 0.0472 payload-growth ratio | PASS |
| Idle TLS memory | 45.597 KiB/connection; maximum 48 | PASS |
| Interoperability, dependencies, deterministic tests and fuzz | all checks | PASS |

Before the final formal run, one frozen `-O2` snapshot repeated the two noisy
performance dimensions. Five idle slopes were 44.599, 46.422, 47.116, 45.329
and 45.252 KiB/connection; the five body-growth samples were 3,936, 4,076,
5,788, 4,860 and 4,504 KiB. A five-round paired bulk check reported ratio
1.3522. This established stable margin before the complete qualification.

## Commands

```text
cangjie_env; timeout 240s cjpm test src/http -j 1 --parallel 1 \
  --filter=Http2FacadeTerminationProfileTest.runsConcurrentFacadeSequenceOneHundredTimesAndTerminates \
  --show-all-output --no-progress --no-color
```

Result: exit 0; one process; rounds 1 through 100 reported three successful
scenario executions each; junit report retained with this evidence.

```text
cangjie_env; timeout 600s cjpm test src/http -j 1 --parallel 1 \
  --exclude-tags=Performance --no-progress --no-color
```

Result: exit 0; 66 passed, 2 explicitly Performance-tagged cases skipped,
0 failed.

```text
cangjie_env; timeout 900s scripts/check
```

Result: exit 0; all tool suites, architecture guard, `cjpm check`, build and
538 non-Performance Cangjie tests passed; 20 explicitly Performance-tagged
tests skipped.

```text
cangjie_env; timeout 900s python3 tools/benchmarks/m3_028_tls.py \
  --repo /home/elliot/playground/Wirestack \
  --stdx-archive /tmp/cangjie-stdx-linux-x64-1.1.3.1.zip \
  --stdx-root /tmp/wirestack-stdx-1.1.3.1.sAN2Jp \
  --output /tmp/m6-025-m3-028-qualified.json
```

Result: exit 0; decision `PASS`.

## Boundaries

This closes M6-025 for native Linux x86_64 glibc only. It does not claim Linux
musl or any non-Linux platform, rerun the one-hour SSE profile, change the public
HTTP/TLS API, modify an SDK/runtime/stdx repository, or push a branch.
