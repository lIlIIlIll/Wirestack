# M0-011 evidence: GATE-NET-06 leak and soak

## Status

- Formal Linux x86_64 workload: **PASS**
- Linux GATE-NET-06 acceptance: **INCOMPLETE**
- M0-011 task and global GATE-NET-06: **INCOMPLETE**

The Linux run completed every minimum workload from PRD GATE-NET-06. It does
not close the gate because the current harness directly measures process RSS
and native file descriptors only. Separate timer, waiter, native-buffer, GC-root
and unreclaimed-background-task counters are not yet present, and the other
required native platforms have not executed this gate.

## Executed Linux workload

| Scenario | Executed | Decision |
|---|---:|---|
| connect/close | 100,000 | PASS |
| peer reset | 100,000 | PASS |
| close during blocked read | 100,000 | PASS |
| TLS failed-handshake cleanup | 100,000 | PASS |
| idle/active mixed soak | 86,400 seconds; 187,051,774 iterations | PASS |

The 24-hour steady-state comparison excluded 288 warmup samples and compared
the first and last 230-sample windows. Median RSS changed from 12,758 KiB to
10,510 KiB (-2,248 KiB); median FD count remained 5. TLS cleanup compared 136
sample windows after excluding 170 warmup samples: median RSS remained 6,844
KiB and median FD count remained 3.

## Reproducibility

- Harness revision: `4323da2`
- Linux: `7.1.9-arch1-2`, x86_64, glibc 2.44
- Cangjie: `1.1.0-alpha.20260817040003`, target
  `x86_64-unknown-linux-gnu`
- AWS-LC source commit: `991e67ff4cf04df4dd89e407f8b920c6936cb56a`
- AWS-LC source tree: `ae54cd9455f9630451d505855afe808a9f028b25`

Full raw reports, process output, exact counters and all timestamped RSS/FD
samples are retained under [`linux_x86_64/`](linux_x86_64/).

## Remaining acceptance work

- Add direct bounded accounting for timers, waiters, native buffers, GC roots
  and background tasks, then prove no monotonic growth.
- Execute native Windows, macOS, Android, iOS and HarmonyOS/OpenHarmony profiles.

Non-execution and unmeasured resource classes never contribute to a COMPLETE
decision.
