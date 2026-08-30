# M7-022 Linux final release soak evidence

Status: COMPLETE

## Scope

M7-022 runs the installed M7-021 Linux x86_64 glibc artifact as the only
Wirestack dependency in a temporary consumer. The mixed workload covers
HTTP/1.1 pooling, concurrent HTTP/2 streams, numbered SSE bodies, request,
stream and connection cancellation, connection churn, idle periods and clean
shutdown. The parent process records RSS, file descriptors, sockets, timerfds,
threads and process count. The consumer reports heavy-GC heap and its owned
waiter, buffer and task counts.

The formal command requires one uninterrupted run of at least 86,400 seconds.
A short run can validate the workload and reporting path, but it cannot produce
an acceptance PASS.

## Final result

The final run used the M7-021 Linux x86_64 glibc artifact with SHA-256
`c0988f62eb657c465a928825573e41e2eb2675241240312bc2228482cbafc9ee`.
The installed-artifact workload ran for 86,400.354 seconds and the enclosing
long gate completed in 86,410.283 seconds without a timeout.

The workload completed 253,704 mixed cycles, 317,130 HTTP/1.1 requests,
792,826 HTTP/2 requests, 253,704 HTTP/2 multiplex batches and 2,029,838
numbered SSE events. It exercised 253,704 request cancellations, 253,704 stream
resets and 31,713 connection cancellation/recovery cycles. All 507,408 spawned
tasks joined, sequence errors remained zero, and terminal waiter, buffer,
background-task and server-task counts were zero. Maximum observed cancellation
latency was 33.315 ms.

The application trend used 289 five-minute samples. Heavy-GC heap changed from
a first-window median of 3,237,888 bytes to a last-window median of 2,893,824
bytes and was not monotonic. The process-tree trend used 1,440 one-minute
samples. FD and socket medians were unchanged, RSS decreased by 9,338 KiB,
thread median growth was 1 within the limit of 2, and timerfd and process counts
were unchanged. Every workload, ownership and resource-trend check returned
`PASS`.

The formal machine reports are
[`linux_x86_64/soak.json`](linux_x86_64/soak.json) and
[`long-check.json`](long-check.json). The bounded raw output is
[`linux_x86_64/soak.log`](linux_x86_64/soak.log), and the current non-long task
report is [`task-check.json`](task-check.json).

### Retained overlapping-run failure

Two formal invocations were found writing the same `soak.log`. The first
runner started at 2026-08-28 13:48 CST. A second systemd runner started at
2026-08-28 19:04 CST. Both opened the same inode and held different write
offsets, so neither output could prove one uninterrupted run. Both process
trees were stopped after their PIDs, process groups and file descriptors were
confirmed. The mixed file is retained as
[`linux_x86_64/soak-overlap-failed-20260829.log`](linux_x86_64/soak-overlap-failed-20260829.log)
and is not acceptance evidence.

The runner now holds a Linux advisory lock for the complete invocation. A
second invocation returns `SOAK_ALREADY_RUNNING` before it builds or starts a
consumer, and it does not replace the active JSON report. Each accepted
invocation also writes a unique log under `build/gates/m7-022-runs/`; the gate
publishes the requested raw-log path only after the child exits cleanly and the
strict output parser accepts the complete stream.

### Historical first formal failure

The 60-second native preflight completed 307 cycles, 614 joined concurrent
tasks and 39 connection cancellation and recovery cycles. Its workload and
resource checks passed. The task, fast and final full non-long gates also
passed.

The first formal attempt failed before the first five-minute application sample
when two concurrent public `HttpClient` response-body requests reported an HTTP
protocol violation. M6-026 retained the reproducer, added a 1,000-batch public
regression and fixed the product defect. The current final artifact includes
that fix, and the formal reports linked above replace the failed attempt as the
acceptance evidence.

The M7-021 archive contains the same SHA-256 content as the current repository
for `src/http/client.cj` and the inspected HTTP/2 client, server, reader and
reset files. The failure is not explained by a stale installed source file.
M6-025's retained profile covers stream cancellation, sibling fairness and
concurrent stream admission, but it does not repeatedly consume two concurrent
small response bodies through the public facade.

## Decision

M7-022 is COMPLETE. One uninterrupted formal run met the 86,400-second minimum
against the final candidate artifact, and every semantic, ownership and
resource bound passed. Short preflights and M0-011's transport-only report were
not used as acceptance substitutes.

## Boundaries

- No runtime, std, stdx or SDK source was modified.
- No SDK component was built.
- No non-Linux platform was tested.
- No remote branch was pushed.
- Historical overlapping runs remain non-acceptance evidence; the completed
  final run used the single-owner gate and an atomically published raw log.
- Artifact signing, update rehearsal and the final candidate report remain
  separate M7-030 and M7-031 work.
