# M7-022 test results

| Check | Result |
|---|---|
| Repository test-plan validator | PASS, 24 paths, 16 scenarios, 12 tests |
| M7-022 and repository-tooling unit tests | PASS, 29 tests |
| Post-M6-026 installed-artifact task preflight | PASS as a 10-second preflight; 52 cycles, 52 H2 multiplex batches, 104/104 joined tasks, 52 request cancellations, 52 stream resets and 7/7 connection recoveries; acceptance remained INCOMPLETE |
| Installed-artifact task preflight | PASS as a short preflight; acceptance remained INCOMPLETE |
| 60-second stability preflight | PASS workload and resource classification; 307 cycles, 614 joined tasks, 39 connection recoveries |
| `scripts/check-fast` | PASS |
| `scripts/check-task M7-022` | PASS |
| Focused existing facade concurrency test | PASS |
| `scripts/check-full` | PASS on final authorized run; `scripts/check` exited 0 |
| Formal `scripts/check-long M7-022` | FAIL after 26.5 seconds with HTTP/2 `ProtocolViolation`; 24-hour acceptance not run to completion |

The post-M6-026 preflight used the requalified M7-021 archive with SHA-256
`aad5b788d3404f80a5934fa5e156ee653e592820651bcc9f0198512a74ce4a04`.
It completed with zero sequence errors and zero terminal application-owned
waiters, buffers, background tasks or server tasks. Heap, RSS, FD, socket,
timerfd, process and thread trends all classified PASS. This is reachability
and cleanup evidence only, not a 24-hour resource-stability claim.

The first sandboxed full gate could not create the unittest runner socket. The
unchanged authorized command then exposed one existing stdnet timing failure.
That exact test passed when isolated, and the next complete authorized full
gate passed. Neither event changes the formal M7-022 failure above.
