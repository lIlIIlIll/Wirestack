# M7-022 Linux final release soak evidence

Status: BLOCKED

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

M7-022 remains BLOCKED. The failed run is not 24-hour evidence and no resource
bound claim is made from it. Do not reduce the workload, relabel a preflight or
reuse M0-011's transport-only report.

Resume M7-022 only after a separate HTTP/2 facade task supplies a public
regression, fixes the product cause, and M7-021 produces and qualifies a new
installed artifact.

## Boundaries

- No runtime, std, stdx or SDK source was modified.
- No SDK component was built.
- No non-Linux platform was tested.
- No remote branch was pushed.
- M7-028 and the later Linux release tasks remain blocked by M7-022.
