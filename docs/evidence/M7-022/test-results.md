# M7-022 test results

| Check | Result |
|---|---|
| Repository test-plan validator | PASS, 25 paths, 17 scenarios, 13 tests |
| M7-022 and repository-tooling unit tests | PASS, 32 tests |
| Final installed-artifact task preflight | PASS as a 10-second preflight; 53 cycles, 53 H2 multiplex batches, 106/106 joined tasks, 53 request cancellations, 53 stream resets and 7/7 connection recoveries; acceptance correctly remained INCOMPLETE |
| 60-second stability preflight | PASS workload and resource classification; 307 cycles, 614 joined tasks, 39 connection recoveries |
| `scripts/check-fast` | PASS |
| `scripts/check-task M7-022` | PASS |
| Focused existing facade concurrency test | PASS |
| Final `scripts/check` | PASS, exit 0; Cangjie 569 PASS, 23 SKIPPED, 0 FAILED, 0 ERROR out of 592; SKIPPED was not counted as PASS |
| Formal `scripts/check-long M7-022` | PASS; 86,410.283 seconds, exit 0, no timeout; workload elapsed 86,400.354 seconds and met all formal parameters |

The final preflight and formal run used the requalified M7-021 archive with
SHA-256
`c0988f62eb657c465a928825573e41e2eb2675241240312bc2228482cbafc9ee`.
The formal run completed 253,704 cycles, 1,109,956 HTTP requests and 2,029,838
SSE events. It joined all 507,408 spawned tasks with zero sequence error and
zero terminal application-owned waiter, buffer, background task or server
task. Heavy-GC heap, RSS, FD, socket, timerfd, process and thread trends all
classified PASS across 289 application samples and 1,440 process-tree samples.

The first sandboxed full gate could not create the unittest runner socket. The
unchanged authorized command then exposed one existing stdnet timing failure.
That exact test passed when isolated, and the next complete authorized full
gate passed. These historical environment events do not change the final
formal M7-022 PASS.
