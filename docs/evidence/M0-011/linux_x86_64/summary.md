# GATE-NET-06 — formal Linux x86_64 workload

**Executed workload:** PASS  
**Linux acceptance:** PASS  
**M0-011/global gate:** INCOMPLETE

| Scenario | Requested | Completed/server total | Decision |
|---|---:|---:|---|
| connect/close | 100,000 | 100,000 | PASS |
| peer reset | 100,000 | 100,000 | PASS |
| close during blocked read | 100,000 | 100,000 | PASS |
| TLS failed-handshake cleanup | 100,000 | 100,000 | PASS |
| mixed idle/active soak | 86,400 s | 187,051,774 | PASS |
| production cancellation cleanup | 100,000 | 100,000 | PASS |
| production TLS transport cleanup | 100,000 | 100,000 | PASS |

The soak retained 1,440 one-minute samples. After warmup exclusion, median RSS
fell by 2,248 KiB and median FD count changed by 0. The TLS cleanup retained 853
quarter-second samples; both steady-state median RSS and FD growth were 0. The
AWS-LC binary had no system TLS dynamic dependency or TLS loader-library string.

The formal count scenarios use coarse one-minute sampling and therefore contain
too few samples for an independent trend decision; their exact completion and
server counters pass. Long-duration RSS/FD trend evidence comes from the 24-hour
mixed soak and the TLS cleanup workload.

The production cancellation run joined all 200,000 spawned tasks and ended with
zero active reads or background tasks. Its post-warmup medians had zero FD,
socket, timerfd and process growth; thread growth was one within the bounded
limit, RSS fell 4,642 KiB, and heavy-GC used heap fell 131,072 bytes. The TLS
run recorded 100,000 engine closes, transport aborts and terminal disposals;
its FD/socket/timerfd/process/thread growth was zero, RSS fell 13,212 KiB, and
heavy-GC used heap grew 569,344 bytes within the 8 MiB bound.

Linux acceptance is therefore complete. The global gate remains incomplete
until Windows, macOS, Android, iOS and HarmonyOS/OpenHarmony run natively.
