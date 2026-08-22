# GATE-NET-01 — Linux x86_64 supplied-SDK result

**Local decision:** PASS  
**Global gate:** INCOMPLETE  
**Warmup:** 2 per scenario  
**Measured samples:** 20 per scenario  
**Wake threshold:** P99 ≤ 50 ms

| Scenario | Decision | Wake P50 | Wake P95 | Wake P99 | Maximum |
|---|---:|---:|---:|---:|---:|
| blocked read + socket close | PASS | 0.134 ms | 0.161 ms | 0.186 ms | 0.186 ms |
| blocked write + socket close | PASS | 0.131 ms | 0.177 ms | 0.196 ms | 0.196 ms |
| pending connect + socket close | PASS | 0.145 ms | 3.459 ms | 4.058 ms | 4.058 ms |
| blocked accept + listener close | PASS | 0.115 ms | 1.049 ms | 1.210 ms | 1.210 ms |

Every measured process exited normally without a harness timeout. Every operation was demonstrated pending before close, and each waiter terminated through the expected typed `SocketException` category. The harness does not match exception-message text.

The result does **not** close the six-platform gate and does not by itself unlock an `UP-*` task.
