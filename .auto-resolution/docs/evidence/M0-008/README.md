# M0-008 evidence: GATE-NET-03 absolute Deadline

## Status

- Task: **COMPLETE**
- Linux x86_64 supplied-SDK gate portion: **PASS**
- Global six-platform gate: **INCOMPLETE**

## Executed scenarios

The supplied SDK compiled and executed four public `std.net` probes at absolute budgets of 50 ms, 200 ms, and 1000 ms:

1. idle blocked read;
2. repeated writes to a peer that does not read;
3. pending connect against a saturated local listen backlog;
4. blocked listener accept.

Each scenario/budget combination retains 20 measured samples. One `Timer.once` owns the budget and calls public `close()`; no mutable per-socket timeout is used as the total budget. The repeated-write loop shares one deadline and must prove progress stopped before close.

## Acceptance result

All 240 measured samples terminated without process timeout. Every case stayed below the PRD overshoot bound `max(20 ms, budget × 5%)`. The largest observed overshoot was 10.359 ms.

See [`linux_x86_64/summary.md`](linux_x86_64/summary.md) for the aggregate table. `manifest.json` records the schema, environment, thresholds and aggregate values. The complete 240-sample JSON report is retained as six byte-exact gzip parts:

```bash
cat result.json.gz.part-* > result.json.gz
gzip -dc result.json.gz > result.json
sha256sum -c SHA256SUMS
```

`SHA256SUMS` pins every part plus the reconstructed gzip and JSON streams.

## Commands

```bash
source /mnt/data/cangjie-sdk/cangjie/envsetup.sh
python3 -m unittest discover -s tools/gates/tests -p 'test_net03_absolute_deadline.py' -v
python3 -m py_compile tools/gates/net03_absolute_deadline.py tools/gates/net03_absolute_deadline_sources.py
bash scripts/gate-net03-absolute-deadline \
  --budgets-ms 50,200,1000 \
  --warmup 2 \
  --repetitions 20
```

Final host-sensitive measurements were executed in serialized scenario groups. Blocked connect was executed in two 10-sample batches per budget to avoid listen-backlog/TIME_WAIT contamination, then merged without filtering samples.

## Scope boundary

No Transport, TLS, HTTP, private socket handle, `CJ_MRT_Sock*`, polling workaround, or exception-message control flow is introduced. Only Linux x86_64 has native evidence, so the global gate remains incomplete.
