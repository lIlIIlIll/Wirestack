# Run Linux protocol and lifecycle fault profiles

Run the M12-003 lifecycle gate against an extracted Wirestack archive and the explicitly selected STS 1.1.3 SDK. It exercises installed native consumers rather than substituting Python facade tests for HTTP, SSE, gzip, or WebSocket behavior.

## Prerequisites

- Linux with `/proc`, Python 3, Python `h2` (the exercised fixture version is 4.4.1), and OpenSSL for temporary test certificates only.
- `$HOME/cangjie_sdk/sts1.1.3` and `$HOME/.codex/scripts/codex_cangjie_env`.
- The verified archive at `docs/evidence/M12-001/native-final/wirestack-baseline.tar.gz`. Its production payload must equal the current checkout. An archive/source mismatch fails before building consumers.
- Disk-backed `$HOME/.cache/agent-tmp` with sufficient free space. No privileged networking, global firewall change, or production fault hook is required.

Other SDKs are rejected before execution. Compiler, runtime files, observed native runtime mappings (or an explicitly marked loader resolution for a very short process), archive, provider, source, probes, and consumer binaries are fingerprinted in the report.

## Run daily smoke

Create a private workspace outside the checkout, then run every profile once. The runner sets `TMPDIR`, `TMP`, and `TEMP` for its subprocesses.

```sh
umask 077
mkdir -p "$HOME/.cache/agent-tmp"
df -T "$HOME/.cache/agent-tmp"
run=$(mktemp -d "$HOME/.cache/agent-tmp/wirestack-lifecycle-smoke.XXXXXX")
python3 tools/gates/m12_003_lifecycle.py \
  --sdk-root "$HOME/cangjie_sdk/sts1.1.3" \
  --archive docs/evidence/M12-001/native-final/wirestack-baseline.tar.gz \
  --scratch "$run/work" --output "$run/evidence" \
  --seed 184003 --mode smoke
```

The current-source smoke report is [STS current smoke](../evidence/M12-003/lifecycle/sts-current-smoke/report.json): 13 profiles passed. A successful invocation exits zero and prints `M12-003 lifecycle PASS: 13 profiles`. A nonzero exit remains a failure; retain its report and raw workspace rather than rerunning until green.

## Run scheduled stress or replay one layer

Stress uses the same barriers and assertions, repeating each profile twenty times by default. It does not introduce retries within a failed operation.

```sh
run=$(mktemp -d "$HOME/.cache/agent-tmp/wirestack-lifecycle-stress.XXXXXX")
python3 tools/gates/m12_003_lifecycle.py \
  --sdk-root "$HOME/cangjie_sdk/sts1.1.3" \
  --archive docs/evidence/M12-001/native-final/wirestack-baseline.tar.gz \
  --scratch "$run/work" --output "$run/evidence" \
  --seed 184003 --mode stress --rounds 20
```

Select `--layer protocol`, `--layer race`, `--layer streams`, or `--layer gzip` instead of all layers. Select `--profile h2_goaway`, for example, to reproduce one scenario with the same seed and a fresh workspace. Keep the original archive, SDK fingerprints, environment, and failure logs alongside a replay; changing them creates a different experiment.

The [executed stress observations](../evidence/M12-003/lifecycle/observations.json) bind 260 passing native profile executions: twenty rounds for each of thirteen profiles. The all-layer final-stress report remains `FAIL` because the stricter race classifier initially had a Cangjie syntax error; its other eleven profiles passed all twenty rounds. The corrected race layer then passed forty executions in [STS final race](../evidence/M12-003/lifecycle/sts-final-race/report.json). The observation aggregate verifies the same SDK, archive, production source, runner, and each actually executed layer's current probe fingerprints; it does not rewrite the failed report or count its build failures as passing executions. Current-source all-layer smoke separately passed after that correction.

Across those selected stress executions, sampled native maxima were 9 FDs, 16 tasks, and 145,548 KiB RSS. Recorded enclosing-budget overshoot was zero. These are observed maxima and budget comparisons, not formal 24-hour resource-drift acceptance. Slow-consumer throughput is derived from exact peer DATA bytes and native elapsed time, with window acknowledgements and live buffer measurements retained per round.

The evidence-decision regression command is:

```sh
python3 -m unittest tools.gates.tests.test_m12_003_lifecycle -v
```

## Profiles and observed fault proof

| Profile | Fault and semantic assertion |
| --- | --- |
| `h2_slowconsumer` | A bounded TLS/H2 wire peer exhausts the slow stream's DATA window before answering a separate headers-only probe. The native client observes live managed storage, then reads exactly 1 MiB of the expected byte. Peer DATA counts, zero-window observations, and WINDOW_UPDATE acknowledgements prove actual backpressure and recovery. |
| `h2_goaway` | The peer sends GOAWAY with `last_stream_id=0`. The rejected operation reports `ConnectionGoAway`; a subsequent exact-byte request must use a different physical connection. |
| `h2_streamscope` | A sibling stream is admitted before the peer sends RST_STREAM on the faulted stream. The terminal code is `StreamReset`; the sibling and a subsequent exact-byte request survive on the same physical connection. |
| `cancel_storm` | Sixteen operations reach an admission barrier. Sixteen actors cancel each source twice. Every operation reports typed cancellation and completes exactly once; all individual cancellation latencies are recorded, then a healthy request succeeds. |
| `rotation_shutdown` | Old and new TLS generations have admitted operations concurrently. A two-actor barrier races resolver rotation/client close against server shutdown. Actual completion counts, generation publication/retention, typed terminals, and terminal resource/generation ledgers are asserted. |
| `sse_cancel`, `sse_cancel_h1` | Exactly 264 event IDs and payloads precede cancellation of a pending receive. Its code is `Cancelled`. An explicit new application session verifies another complete 264-event sequence and EOF. |
| `websocket_disconnect`, `websocket_disconnect_h1` | Exactly 264 messages and sequence ACKs precede peer interruption of a pending receive. Its code is `TransportFailure`. An explicit reconnect verifies another complete 264-message sequence. |
| `websocket_fragmented` | Native H2 WebSocket messages include fragmentation, interleaved ping, automatic pong, exact reassembled payload, and exact ACK semantics. |
| `sse_h1`, `websocket_h1` | TLS-backed H1 baselines retain exact event/message sequence semantics and terminal cleanup. |
| `gzip_faults` | Installed H1/H2 gzip consumers verify incremental exact decoded bytes, wire metadata separation, typed output-limit and checksum faults, bounded decoder work/storage, and shutdown. |

Recovery is explicit application policy, not transparent retry or automatic SSE `Last-Event-ID` resume. H1 interruption profiles require a new physical connection. H2 per-stream failure need not discard a healthy physical connection. The Python wire fixture uses bounded test sockets and frame encoding; native consumers use public Wirestack APIs and the existing StdNet adapter, not `std.net` outside that adapter.

## Read measurements without conflating counters

`process_measurements` and `process_highwater` report sampled native FD count, task count, and RSS in KiB separately from public managed buffer/owner/request/stream ledgers. Sampling is bounded and cannot guarantee capture of every instantaneous peak. SSE writer storage is bounded to 128 bytes; stream client/server resource snapshots assert their configured ceilings. H2 peer windows are wire observations, not invented local window counters.

`operation_measurements` retain per-receive, cancellation, or fault completion latency and overshoot relative to the enclosing operation/join budget. Rotation/shutdown endpoint latencies are conservative upper bounds observed after both terminal joins, not individual scheduler completion timestamps. Cancellation has no second timeout owner. These measurements do not claim that an operation deadline expired or that a short run meets a 24-hour drift bound. Public cancellation-registration and local H2 window counters are explicitly `UNAVAILABLE`; they must not be interpreted as zero.

Fault admission, publication, sequence consumption, cancellation entry, and rotation/shutdown ordering use events or condition barriers with absolute deadlines, not timing sleeps. The reused gzip cleanup observer polls an actual public ledger with a bounded deadline; it does not schedule faults or retry failed requests.

Owned process groups, native consumers, peer sockets/thread, samplers, handlers, configurations, and pending operations have bounded cleanup, including timeout and interruption. Command logs are bounded to 1 MiB per stream and published paths are normalized. Native future cancellation diagnostics may appear on stderr; the accepted typed terminal and joined completion/cleanup assertions determine the result, not absence of diagnostics.

## Qualification boundary

Smoke and scheduled stress are source-bound development evidence only. Every report declares `formal_86400: NOT_RUN` and `release_qualification: NOT_QUALIFIED`. No short profile is the formal 86,400-second candidate gate. Retain earlier failures in `docs/evidence/M12-003/lifecycle/`; do not rewrite them as passing evidence. Shared M12-003 orchestration owns formal-campaign scheduling and the task's overall acceptance status.
