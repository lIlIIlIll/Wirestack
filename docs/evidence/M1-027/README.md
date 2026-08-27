# M1-027 background OperationContext performance evidence

## Status

- Task: `M1-027`
- Platform: Linux x86_64 glibc
- Result: **COMPLETE**
- Compiler: Cangjie `1.1.0-alpha.20260817040003`, `cjnative`
- Build mode: `-O2`

The retained Wirestack-only background fast path lowers the fixed cost of
`StdNetTransport.readSome` without changing cancellation, Deadline, lifecycle,
or terminal semantics. The required five-payload GATE-NET-05 comparison passes.

Raw reports:

- [pre-optimization profile](linux_x86_64/baseline-profile.data)
- [final per-call profile](linux_x86_64/final-profile.data)
- [final 5 payload x 11 round NET-05 report](linux_x86_64/final-net05-formal11.data)

## Experiment

The profile compiles one release unittest binary from a repository snapshot.
Each timing stage runs five process repetitions. The hot loops use 1,000,000
iterations, except the more expensive stages. `perf stat` records user-space
cycles and instructions; a separate 10,000-iteration `heaptrack` run records
native process allocation events. The metric does not claim exact managed-heap
allocations for an individual Cangjie expression.

The formal gate uses the same fair process shape as M0-010: one `-O2` unittest
binary, one warmup, eleven alternating measured rounds, and payloads of 1 KiB,
16 KiB, 64 KiB, 1 MiB and 100 MiB.

## Cost decomposition

| Stage | Baseline P50 ns/call | Final P50 ns/call | Final cycles/call |
|---|---:|---:|---:|
| control loop | 2.065 | 1.103 | 34.292 |
| background cancellation/deadline check | 15.262 | 9.263 | 95.547 |
| future Deadline check | 95.229 | 57.139 | 280.859 |
| none-token register/unregister | 54.616 | 20.125 | 136.392 |
| cancellable register/unregister | 229.331 | 118.432 | 682.574 |
| allocate and complete operation gate | 40.558 | 24.930 | 112.513 |
| empty background `readSome` | 297.042 | 92.110 | 481.761 |
| assign `readTimeout = None` | 22.588 | 12.049 | 441.904 |
| ready background read | not measured | 1,288.604 | 3,497.348 |
| ready observed read | not measured | 1,198.216 | 3,793.661 |

The empty background call falls from 297.042 ns to 92.110 ns, a 69.0%
reduction. The final ready-I/O wall-time samples still include scheduler noise:
the background P50 is 90.388 ns slower than the observed P50, while its cycle
count is 7.8% lower. The formal paired gate, not this independent-process
difference, determines acceptance.

Native allocation deltas and every raw timing sample remain in the profile.
Heaptrack counts process allocation events and do not claim exact managed-heap
allocations for one Cangjie expression.

## Fast-path boundary

The fast path applies only when the context has no Deadline, uses the singleton
non-cancellable token, and has no trace or event sink. It skips the context
precheck, cancellation registration, and `OperationGate`. Lifecycle claims,
same-direction concurrency rejection, EOF checks, close and abort mapping, and
copy accounting remain shared with the generic path.

`CancellationToken.permanentlyActive` changes from `private` to `protected` so
the sibling `transport_stdnet` package in the same module can classify the
singleton. The Cangjie class compatibility rule for a module-invisible instance
field states that access-modifier changes among `public`, `protected`,
`internal`, and `private` are compatible. The field type, order, and value do
not change, so object layout is unchanged. The declaration-level `diff-risk`
parser reports `incompatible`, but it matches only unrelated global/static-let
and alias scenarios; this is a documented parser false positive against the
more specific class-instance-field rule. The current compiler also compiled
the sibling-package access successfully.

The adapter no longer broadcasts its test-only read condition at every
`beginRead` and `endRead`. `waitUntilReadActive` uses the same bounded 1 ms
polling strategy as the listener diagnostic. Generic Deadline/cancellation
paths reset socket timeouts in `finally`, so a later background operation does
not inherit a timeout and does not need to rewrite `None` on every call.

## Formal GATE-NET-05 result

| Payload | Raw P50 MiB/s | Adapter P50 MiB/s | Throughput ratio | P95 latency ratio | Result |
|---|---:|---:|---:|---:|---|
| 1 KiB | 39.373 | 53.761 | 1.365428 | 0.943396 | PASS |
| 16 KiB | 293.064 | 351.147 | 1.198192 | 0.990445 | PASS |
| 64 KiB | 376.039 | 371.654 | 0.988339 | 0.333576 | PASS |
| 1 MiB | 380.936 | 397.305 | 1.042970 | 0.967290 | PASS |
| 100 MiB | 507.981 | 566.291 | 1.114788 | 0.961544 | PASS |

Every instrumented whole-array adapter sample reports zero staging read and
write copies and exact payload/read-size accounting. All five payloads meet the
throughput ratio minimum of 0.95 and the P95 latency ratio ceiling of 1.10. The
gate retains all eleven samples, including scheduler outliers; no threshold,
payload, round, or percentile rule changed.

## Verification

Commands and exact results:

```text
env DISABLE_ZOXIDE=1 /home/elliot/.codex/scripts/codex_cangjie_env --cwd /home/elliot/playground/Wirestack cjpm test '--filter=M127BackgroundFastPathTest.*' --no-color --no-progress
PASS: 6 passed, 0 failed

scripts/profile-m1-027-operation-context --output /tmp/wirestack-m1-027-final-fastpath-profile.json --artifact-dir /tmp/wirestack-m1-027-final-fastpath-profile --repository-revision workspace-m1-027-background-fastpath-final
PASS: all ten cost stages measured with perf and heaptrack

bash scripts/gate-net05-large-buffer-profile --warmup 1 --repetitions 11 --output /tmp/wirestack-m1-027-final-candidate-net05.json --artifact-dir /tmp/wirestack-m1-027-final-candidate-net05-artifacts --repository-revision workspace-m1-027-background-fastpath-final-candidate
PASS: all 5 payload comparisons passed; all instrumented staging-copy counts are 0

scripts/check
PASS: Python suites 50 + 102 + 11; architecture guard and cjpm check/build pass; Cangjie project total 534, passed 518, skipped 16, failed 0
```

The first sandboxed unittest attempt compiled but the runner could not create
its local control socket (`Operation not permitted`). The identical commands
above passed in the authorized environment; no product code was changed to
work around the sandbox.

## Remaining risk

Short loopback samples remain sensitive to scheduler and CPU-frequency noise.
The retained report passes without CPU pinning and keeps every outlier. Future
performance CI should record affinity and governor metadata, but that does not
change this task's fixed acceptance rule. `UP-004` is not required to close
M1-027 and remains a separate conditional upstream task.
