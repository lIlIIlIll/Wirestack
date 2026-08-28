# M7-027 test results

| Check | Result |
|---|---|
| Test-plan validator | PASS, 18 paths, 15 scenarios, 12 tests |
| Gate fault-injection tests | PASS, 9 tests |
| Static public-import guard | PASS |
| Temporary clean-consumer build | PASS |
| Native clean-consumer run | PASS, 9 markers |
| API freeze gate | PASS, 147 declarations and 105 resolved aliases |
| Focused cancellation reproduction | PASS, 10/10 isolated runs |
| Repository `scripts/check` | PASS on final run: 113 repository tests, 131 gate-runner tests, 23 benchmark-tool tests, architecture/check/build PASS, 558 Cangjie tests passed, 22 skipped, 0 failed |
| Evidence freshness | PASS after final seal |

The first complete `scripts/check` run observed one unrelated timing failure in
`StdNetTransportTest.cancellationWakesBlockedReadAndIsNeverReportedAsEof`.
The exact case then passed 10/10 isolated reruns and passed in the final complete
run. M7-027 does not change transport production code.

Long-running profiles were not part of this task. The one-hour SSE profile and
24-hour release soak were not run.
