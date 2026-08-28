# M7-022 test results

| Check | Result |
|---|---|
| Repository test-plan validator | PASS, 24 paths, 16 scenarios, 12 tests |
| M7-022 and repository-tooling unit tests | PASS, 29 tests |
| Installed-artifact task preflight | PASS as a short preflight; acceptance remained INCOMPLETE |
| 60-second stability preflight | PASS workload and resource classification; 307 cycles, 614 joined tasks, 39 connection recoveries |
| `scripts/check-fast` | PASS |
| `scripts/check-task M7-022` | PASS |
| Focused existing facade concurrency test | PASS |
| `scripts/check-full` | PASS on final authorized run; `scripts/check` exited 0 |
| Formal `scripts/check-long M7-022` | FAIL after 26.5 seconds with HTTP/2 `ProtocolViolation`; 24-hour acceptance not run to completion |

The first sandboxed full gate could not create the unittest runner socket. The
unchanged authorized command then exposed one existing stdnet timing failure.
That exact test passed when isolated, and the next complete authorized full
gate passed. Neither event changes the formal M7-022 failure above.
