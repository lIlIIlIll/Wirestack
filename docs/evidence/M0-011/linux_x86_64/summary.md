# GATE-NET-06 — formal Linux x86_64 workload

**Executed workload:** PASS  
**Linux acceptance:** INCOMPLETE  
**M0-011/global gate:** INCOMPLETE

| Scenario | Requested | Completed/server total | Decision |
|---|---:|---:|---|
| connect/close | 100,000 | 100,000 | PASS |
| peer reset | 100,000 | 100,000 | PASS |
| close during blocked read | 100,000 | 100,000 | PASS |
| TLS failed-handshake cleanup | 100,000 | 100,000 | PASS |
| mixed idle/active soak | 86,400 s | 187,051,774 | PASS |

The soak retained 1,440 one-minute samples. After warmup exclusion, median RSS
fell by 2,248 KiB and median FD count changed by 0. The TLS cleanup retained 853
quarter-second samples; both steady-state median RSS and FD growth were 0. The
AWS-LC binary had no system TLS dynamic dependency or TLS loader-library string.

The formal count scenarios use coarse one-minute sampling and therefore contain
too few samples for an independent trend decision; their exact completion and
server counters pass. Long-duration RSS/FD trend evidence comes from the 24-hour
mixed soak and the TLS cleanup workload.

This evidence does not directly count timers, waiters, native buffers, GC roots
or background tasks. Those PRD acceptance classes remain unmeasured, so the
Linux gate remains INCOMPLETE despite the executed workload PASS.
