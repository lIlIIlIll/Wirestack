# M0-011 evidence: GATE-NET-06 leak and soak

## Status

- Formal Linux x86_64 workload: **PASS**
- Linux GATE-NET-06 acceptance: **PASS**
- M0-011 task: **BLOCKED**; global GATE-NET-06: **INCOMPLETE**

The Linux run completed every minimum workload from PRD GATE-NET-06. A separate
production-path closeout completed 100,000 explicit cancellations through
`StdNetTransport` and 100,000 failed handshakes through `TlsConnection`. It
records process-tree socket, timerfd, thread, FD and RSS trends, heavy-GC heap
checkpoints, exact waiter/task joins and exactly-once TLS disposal. The global
task remains blocked because the other required native platforms have not run.

## Executed Linux workload

| Scenario | Executed | Decision |
|---|---:|---|
| connect/close | 100,000 | PASS |
| peer reset | 100,000 | PASS |
| close during blocked read | 100,000 | PASS |
| TLS failed-handshake cleanup | 100,000 | PASS |
| idle/active mixed soak | 86,400 seconds; 187,051,774 iterations | PASS |
| production cancellation cleanup | 100,000 | PASS |
| production TLS transport cleanup | 100,000 | PASS |

The 24-hour steady-state comparison excluded 288 warmup samples and compared
the first and last 230-sample windows. Median RSS changed from 12,758 KiB to
10,510 KiB (-2,248 KiB); median FD count remained 5. TLS cleanup compared 136
sample windows after excluding 170 warmup samples: median RSS remained 6,844
KiB and median FD count remained 3.

## Reproducibility

- Harness revision: `4323da2`
- Production cleanup revision: `e35365ae82775e639cf39c57e82c42f07e5f3b93`
- Linux: `7.1.9-arch1-2`, x86_64, glibc 2.44
- Cangjie: `1.1.0-alpha.20260817040003`, target
  `x86_64-unknown-linux-gnu`
- AWS-LC source commit: `991e67ff4cf04df4dd89e407f8b920c6936cb56a`
- AWS-LC source tree: `ae54cd9455f9630451d505855afe808a9f028b25`

Full raw reports, process output, exact counters and all timestamped RSS/FD
samples are retained under [`linux_x86_64/`](linux_x86_64/).

## Windows supplemental gate

The repository contains a fixed `windows-2025` / x86_64 workflow and a
fail-closed validator for a four-hour mixed lifecycle profile. The workflow
records Win32 RSS/private bytes/handles, PowerShell thread counts and
`netstat -ano` socket counts, binds the report to `GITHUB_SHA`, and uploads the
raw probe output. The probe now accepts a Windows-only cleanup cadence and the
workflow passes `gcEvery=256`, so completed async work is collected during the
run. Linux invocations omit this optional argument and keep their original
workload. Run
[`33602643549`](https://github.com/lIlIIlIll/Wirestack/actions/runs/33602643549)
checked out `23c14f22ad24fa2c82ad7fba8b73665ad97a8b61`, passed the validator and
native capability preflight, and ran the profile for `14,400` seconds. The
profile is retained under [`windows-x86_64/`](windows-x86_64/), but it is
**FAIL**, not PASS: the mixed workload completed, while the resource trend
exceeded the bounds (`handle_count` growth `244` > `8`, `private_kib` growth
`65068` > `8192`) and one thread query was unavailable. The report therefore
does not close the Windows supplemental gate or global M0-011.

### Latest post-fix native rerun

Run [`33705670217`](https://github.com/lIlIIlIll/Wirestack/actions/runs/33705670217)
checked out `2a73c866c64d6ef94da2f486055ea9e6bd377927` on the same
`windows-2025` / AMD64 image and completed the full `14,400`-second workload
with `1,267,504` iterations and `gcEvery=256`. The validator retained a FAIL:
handle-count growth was `127` (limit `8`) and private-byte growth was `65,704
KiB` (limit `8,192 KiB`). RSS growth was `36 KiB`, thread/socket growth was
zero, and all resource classes were measured without sampler errors. The exact
environment, report and validator output are retained as
[`environment-33705670217.json`](windows-x86_64/environment-33705670217.json),
[`long-4h-33705670217.json`](windows-x86_64/long-4h-33705670217.json) and
[`validation-33705670217.json`](windows-x86_64/validation-33705670217.json).
The run proves the native gate executes after the probe change; it does not
prove Windows resource acceptance.

## Remaining global acceptance work

- Resolve the remaining native Windows resource growth. The post-fix run
  `33705670217` still fails handle/private-byte bounds and is retained beside
  the original run `33602643549`; neither report is rewritten.
- Execute native macOS, Android, iOS and HarmonyOS/OpenHarmony profiles.
- Keep the required 24-hour Linux release-candidate soak as the global
  GATE-NET-06 duration; the Windows four-hour profile does not replace it.

Non-execution and unmeasured resource classes never contribute to a COMPLETE
decision.
