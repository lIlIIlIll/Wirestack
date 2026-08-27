# M2-003 Linux bounded resolver backend evidence

- Task: `M2-003`
- Profile: Linux x86_64 glibc
- Result: **PASS**
- Date: 2026-08-27, UTC+8
- Compiler: Cangjie `1.1.0-alpha.20260817040003`, `cjnative`
- Target: `x86_64-unknown-linux-gnu`

## Scope

M2-003 adds the internal production backend required by DNS-004. Blocking
`getaddrinfo` calls run on an instance-owned fixed pthread pool rather than on
Cangjie scheduler carriers. Admission is FIFO and bounded by a configured
worker count plus queue capacity. The Cangjie caller polls completed native
state with scheduler-aware sleeps while enforcing the canonical
`OperationContext` cancellation token and absolute Deadline.

The implementation does not import `std.net`, call private `CJ_MRT_*` APIs,
create one thread per request, or add an epoll/kqueue/IOCP loop. M2-005 retains
ownership of the public Linux `SystemResolver` facade and stable platform error
mapping.

## Explicit bounds and lifecycle

| Resource or operation | Bound / rule |
|---|---|
| worker threads | configurable `1..32`; fixed for the pool lifetime |
| queued requests | configurable `1..1024`; overload fails immediately |
| active native jobs | no more than `workerCount + queueCapacity` |
| addresses per result | caller limit, hard-capped at `1024` |
| host/service copies | 253 and 63 bytes respectively |
| caller polling | one reusable output allocation; at most 1 ms sleep quantum |
| cancellation / Deadline | releases the caller reference promptly; queued work is skipped and running work cleans up on its worker |
| close | rejects new submission, drains references, joins fixed workers; repeated close is harmless |

Pool metrics expose configured bounds, current active/queued/running jobs,
peaks, submissions, completions and overload rejections. They retain no host or
address values.

## Acceptance matrix

| Criterion | Evidence | Result |
|---|---|---|
| blocking DNS does not occupy scheduler carriers | eight delayed resolutions on two native workers while a Cangjie heartbeat advances at least 20 times | PASS |
| thread and queue counts are bounded | constructor boundary tests; `peakActiveJobs <= 2`, `peakQueuedJobs <= 1`, and exactly one overload rejection in the 1+1 profile | PASS |
| cancellation is prompt and cleanup-safe | 200 ms native call; caller observes `Cancelled` in under 50 ms; close waits for worker cleanup | PASS |
| Deadline is prompt and cleanup-safe | 20 ms Deadline against a 200 ms native call; caller observes `Timeout` in under 50 ms; close waits for worker cleanup | PASS |
| pre-cancellation has no native side effect | cancelled context returns before submit; submitted metric remains zero | PASS |
| native work is actually isolated and delayed | 14/14 `getaddrinfo` calls intercepted; each lasts 200.154–202.233 ms; maximum native concurrency is exactly two | PASS |
| private runtime ABI excluded | architecture guard passes and the content-addressed build manifest records `private_runtime_abi: false` | PASS |
| artifact is reproducible and validated | source/header/compiler/target fingerprint, archive SHA-256, cache digest revalidation and native create/metrics/destroy smoke | PASS |

Raw retained artifacts:

- [`linux_x86_64/report.json`](linux_x86_64/report.json): machine-readable gate decision, commands, toolchain fingerprint and metrics.
- [`linux_x86_64/focused-test.log`](linux_x86_64/focused-test.log): focused Cangjie unittest output.
- [`linux_x86_64/gai-delay.log`](linux_x86_64/gai-delay.log): paired native `getaddrinfo` enter/exit records with OS thread IDs.

## Commands and exact results

Deterministic delayed acceptance:

```text
env DISABLE_ZOXIDE=1 /home/elliot/.codex/scripts/codex_cangjie_env --cwd /home/elliot/playground/Wirestack scripts/gate-m2-003-resolver-pool --output-dir docs/evidence/M2-003/linux_x86_64
```

Exit 0. Gate `M2-003-BOUNDED-RESOLVER-POOL` reports `PASS`, zero failures,
8 focused cases passed, 14 paired delayed native calls and maximum native
concurrency 2. The first gate run also executed all focused cases successfully,
but the gate parser failed closed because it counted `FAILED: 0` as a failure
and the initial expected-call model omitted one ordinary localhost lookup. The
parser and its unit tests were corrected before the retained rerun.

Canonical repository gate:

```text
env DISABLE_ZOXIDE=1 /home/elliot/.codex/scripts/codex_cangjie_env --cwd /home/elliot/playground/Wirestack ./scripts/check
```

Exit 0. Python suites passed 53/53, 105/105 and 11/11. The architecture guard,
native resolver build/smoke, `cjpm check`, `cjpm build`, and the full Cangjie
suite passed. The full Cangjie result was 542 total, 526 passed, 16 skipped,
0 failed and 0 errors. The build emits three expected unused-internal warnings
for the backend methods reserved for M2-005, plus the existing
`waitUntilAcceptActive` and `waitUntilWaiters` warnings.

## Compatibility and remaining boundary

The backend is internal and adds no public API or ABI. `checkResolveContext`
changes from private to internal only within the resolver package group.

This evidence is native Linux x86_64 glibc evidence for the platform-independent
bounded backend. It does not claim Linux-musl `SystemResolver` acceptance.
M2-005 still must integrate this backend into the public resolver, preserve all
candidates, expose stable native error evidence, avoid invented TTLs and pass
on both glibc and a real musl target. Until that task completes, Wirestack does
not expose this backend as its production public DNS path.
