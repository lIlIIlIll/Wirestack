# GATE-NET-06 — bounded Linux x86_64 result

**Bounded execution:** PASS  
**M0-011 task:** INCOMPLETE  
**Global gate:** INCOMPLETE

| Scenario | Iterations | Client completion | Server total | Decision |
|---|---:|---:|---:|---|
| connect/close | 2,000 | 2,000 | 2,000 accepts | PASS |
| active echo/connect/close | 1,000 | 1,000 | 1,000 exact echoes | PASS |
| peer reset | 1,000 | 1,000 | 1,000 RST closes | PASS |
| close during blocked read | 500 | 500 | 500 accepts | PASS |

Each process was sampled through `/proc/<pid>/status` and `/proc/<pid>/fd`.
The report retains raw timestamped RSS and FD arrays plus first, last, min, max,
P50, P95 and P99 aggregates. All server accept totals and echo byte totals
matched the requested iteration counts.

This bounded result is not evidence for 100,000 iterations, TLS handshake
cleanup, a 24-hour soak or another platform. Those entries remain explicitly
`NOT_RUN`, `NOT_YET_APPLICABLE` or `BLOCKED`.
