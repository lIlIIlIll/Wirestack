# M7-022 Linux final release soak evidence

Status: IN_PROGRESS

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

## Current result

After M6-026 completed and M7-021 produced a newly qualified artifact, the
non-long task gate passed again. The 10-second installed-artifact preflight
completed 52 mixed cycles, 52 HTTP/2 multiplex batches, 104 joined concurrent
tasks, 52 request cancellations, 52 stream resets and 7 connection
cancellation/recovery cycles. It completed 65 HTTP/1.1 requests, 164 HTTP/2
requests and 416 numbered SSE events with zero sequence error and zero terminal
waiter, buffer, background-task or server-task owner. Application heap and all
sampled process-tree resource trends passed.

The preflight correctly remains `INCOMPLETE`: its 10-second duration does not
meet the formal 86,400-second parameter. The machine report is
[`linux_x86_64/preflight-after-m6-026.json`](linux_x86_64/preflight-after-m6-026.json),
and the non-long task report is
[`task-check-after-m6-026.json`](task-check-after-m6-026.json).

### Retained first formal failure

The 60-second native preflight completed 307 cycles, 614 joined concurrent
tasks and 39 connection cancellation and recovery cycles. Its workload and
resource checks passed. The task, fast and final full non-long gates also
passed.

The formal gate then failed before the first five-minute application sample.
Two concurrent public `HttpClient` response-body requests threw
`HttpException: HTTP protocol violation`. The runner stopped the process group
and wrote [`linux_x86_64/soak.json`](linux_x86_64/soak.json),
[`linux_x86_64/soak.log`](linux_x86_64/soak.log) and
[`long-check.json`](long-check.json). The long check returned exit 1 after
26.5 seconds, including the clean-consumer build.

The M7-021 archive contains the same SHA-256 content as the current repository
for `src/http/client.cj` and the inspected HTTP/2 client, server, reader and
reset files. The failure is not explained by a stale installed source file.
M6-025's retained profile covers stream cancellation, sibling fairness and
concurrent stream admission, but it does not repeatedly consume two concurrent
small response bodies through the public facade.

## Decision

M7-022 is no longer blocked by the HTTP/2 facade failure. M6-026 supplies the
1,000-batch public regression and product fix, M7-021 requalified the installed
artifact, and the unchanged mixed workload now passes the short preflight.

The task remains IN_PROGRESS until one uninterrupted formal run reaches at
least 86,400 seconds and every semantic and resource bound passes. Do not
reduce the workload, relabel a preflight or reuse M0-011's transport-only
report.

## Boundaries

- No runtime, std, stdx or SDK source was modified.
- No SDK component was built.
- No non-Linux platform was tested.
- No remote branch was pushed.
- The formal 24-hour run was not restarted in this update.
- M7-028 and the later Linux release tasks remain blocked by M7-022 completion.
