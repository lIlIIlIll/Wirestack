# Linux resource fault profiles

M12-003 runs installed public Wirestack consumers on an explicitly selected STS SDK. The resource runner extracts and verifies the selected archive, checks its production sources against the checkout, and hides the checkout during consumer build and execution. This is uncommitted task evidence, not release qualification.

```sh
python3 tools/gates/m12_003_resources.py \
  --sdk-root "$HOME/cangjie_sdk/sts1.1.3" \
  --archive docs/evidence/M12-001/native-final/wirestack-baseline.tar.gz \
  --scratch "$HOME/.cache/agent-tmp/wirestack-m12-003/resources" \
  --output docs/evidence/M12-003/resources \
  --seed 184003
python3 -m unittest tools.gates.tests.test_m12_003_resources -v
```

Use `--profile buffers|requests|pool|streams|resolver|low_fd|cpu|memory|memory_pressure` to replay one profile. The default runs all nine without retry. Seed identifies the replay; there is no randomized scheduling. Admission state, native UDP receipt, cancellation, and retained response ownership control the races. The runner creates a fresh private directory below the supplied scratch path on each invocation. It refuses tmpfs or less than 1 GiB free space.

## Isolation and effective limits

Each profile owns one uniquely named systemd user scope. Supported profiles use `CPUQuota=25%` and `MemoryMax=512M`. The isolated pressure classifier uses `CPUQuota=100%` and `MemoryMax=96M`; it does not add CPU starvation to the memory classification experiment. The driver reads `cpu.max`, `cpu.stat`, `memory.max`, and `memory.events` inside that scope. The CPU profile spends at least 600 ms of native thread CPU time on bounded computation, then exercises real public buffer admission and cancellation. It requires positive deltas for both `nr_throttled` and `throttled_usec`, not just successful systemd property assignment.

The low-FD child inherits `RLIMIT_NOFILE=64`. A consumer-only C helper reads back the effective limit, retains `/dev/null` descriptors until `EMFILE`, then releases only its own descriptors. Wirestack's public `TcpListener.bind` must refuse while exhausted and succeed after release. The helper does not access Wirestack handles or private runtime APIs. A private bubblewrap mount namespace retains native device visibility and hides the source checkout. No shared host network or firewall configuration changes.

The driver bounds each child's output to 1 MiB per stream and its lifetime to 30 seconds. The outer runner also bounds command streams, timeouts, and owned process groups. Every scope is stopped in `finally`; the UDP fixture stops and joins, and every native child is reaped. Evidence retains failures instead of replacing them with a later successful retry. The earlier combined 25%-CPU/96-MiB experiment timed out after 30,181 ms with SIGKILL, zero kernel OOM counters, and successful cleanup. Its exact seed, bindings, source digests, commands and results remain FAIL in `docs/evidence/M12-003/resources/mixed-pressure-failure.json`. The isolated memory experiment is a different configuration, not a rerun claiming that combined profile recovered.

## Scenarios and semantic assertions

All native scenarios are in `examples/linux/m12_003/resources/main.cj`. Fault instrumentation is limited to that example directory.

| Stable profile | Coverage key | Native path and assertions | Feature mapping |
|---|---|---|---|
| `resource_buffers` | `buffer_quota` | `buffers`: retain all 131,072 bytes of the route/origin DATA allowance; observe one admission waiter; reject an additional waiter; cancel the retained waiter; reject a second owner while the first is live; expire a 100 ms absolute deadline; release and reacquire the full allowance | M10-002 aggregate buffer, owner and waiter budgets; M10-001 shared deadline; M10-003 cancellation; M10-005 observation |
| `resource_requests` | Additional request coverage | `exchanges("requests")`: hold one real H1 response against a one-request ceiling; observe blocked admission; cancel and expire waiting requests; close the retained response; receive a complete new response | M10-002 request admission |
| `resource_pool` | `pool_quota` | `exchanges("pool")`: retain the only physical connection; observe an additional admitted request blocked on capacity; cancel and expire it; release the response; receive a complete response | M10-002 aggregate connection budget |
| `resource_streams` | `stream_quota` | `exchanges("streams")`: negotiate actual TLS ALPN H2; retain one active stream against a one-stream ceiling with two available connection slots; cancel and expire blocked stream admission; release; receive a complete H2 response | M10-002 stream budget; M10-003 cancellation |
| `resource_resolver` | `resolver_quota` | `resolverChecks`: one DNS worker and one queue slot; native UDP fixture receives and drops the active query; observe active=1 and queued=1; refuse overflow with `TemporaryFailure`; deadline queued work and cancel active work; answer a new query and observe active/queued/running=0 and exactly one rejection | M8 bounded wire DNS; M10-005 resolver counters |
| `resource_low_fd` | `low_fd` | `lowFd`: prove effective 64-FD ceiling and actual EMFILE; public socket refusal; release owned descriptors; public native bind recovery | M9 native socket capability path |
| `resource_cpu` | `low_cpu` | Native thread-CPU load and positive cgroup throttling deltas; `buffers` under the quota | M10 budgets, deadlines, cancellation |
| `resource_memory` | `low_memory` | Prove effective 512 MiB cap; `buffers` exercises library refusal and post-release recovery without process OOM | M10 managed-buffer admission |
| `resource_memory_pressure` | Diagnostic classification | Allocate and retain touched managed arrays under 96 MiB; require allocation evidence and a positive memory-limit event; catch the public STS `OutOfMemoryError`, emit a typed result and exit 23; distinguish counter-proven kernel oom-kill | STS runtime and kernel boundary, not a supported configuration |

ResourceExhausted admission, Deadline/TimedOut, Cancelled, DNS queue refusal, native socket failure and kernel OOM remain distinct. A signal alone is not proof of OOM. The runner rejects OOM in a supported profile even if a PASS marker is present. The pressure consumer's native outcome remains FAIL and `library_acceptance` is NOT_APPLICABLE_UNSUPPORTED_CONFIGURATION. A PASS diagnostic validates only the observed runtime/kernel boundary, never library refusal or supported operation. STS 1.1.3 execution captured the public `OutOfMemoryError` with one typed marker and dedicated exit 23; exception wording does not control classification. Unknown nonzero exits remain runtime/native failures and cannot satisfy typed OOM validation.

## Resource and timing evidence

`docs/evidence/M12-003/resources/current/report.json` binds compiler, runtime, std.net, archive, production inputs, provider manifests, native consumer, runner and example source. It records normalized commands and exit status, coverage keys, semantic criteria, fault proof, recovery and cleanup. `supported_tier_status` covers eight supported scenarios; current `status` also requires the separately classified negative pressure experiment. Historical diagnostics keep their original FAIL verdicts and hashes in `diagnostics`/`historical_diagnostic_status`; they are not rewritten or treated as supported operation. The combined 25%-CPU/96-MiB timeout has no recovery claim. `earlier-runtime-oom.json` retains the earlier uncaught observation with its actual binary/source bindings. `typed-memory/report.json` records the materially changed typed consumer, not an unchanged retry.

The driver samples native FD count, OS tasks and RSS throughout execution. Native stdout markers align before, during and after samples with the scenario. Peak samples are separate. Client snapshots expose active/reserved connections, active requests, active/reserved streams, managed-buffer bytes, owner rows, admission waiters and pool waiters. After close, every exposed logical live count must be zero. Resolver active/queued/running work must also return to zero. Rejection totals are lifetime counters and do not return to zero.

There is no public reserved-request or cancellation-registration counter. These are reported as unavailable, never invented as zero. A successful native operation join proves termination, not an inferred registration count. RSS and runtime OS task retention are sampled facts, not logical ownership counts. Neither is substituted for public ledger cleanup.

The native consumer reports actual elapsed deadline duration and cancellation-to-join duration. This low-CPU smoke enforces no more than one second of deadline overshoot or cancellation completion. It does not establish the PRD's P99 50 ms cancellation target; that requires a repeated latency campaign. Recovery after resource release uses a complete native response or a successful public quota reacquisition. These quota profiles do not damage a connection; excluding unhealthy connections is exercised by the separate network/protocol families.

Daily smoke and scheduled repeated stress are distinct from the formal 86,400-second candidate soak. No short resource run claims the formal soak passed, and this task does not execute M12-004.
